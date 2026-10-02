defmodule ControlPlane.Fleet.StilleNodesTest do
  @moduledoc """
  Een node die wegvalt wordt gemeld -- één keer, en niet te vroeg.

  Maastricht viel op 24 september weg en op 2 oktober had niemand het gemerkt:
  `mark_stale_nodes_offline/0` zette de status om en vertelde dat aan open
  dashboards, aan niemand anders. Dit legt vast wanneer er wél gemeld wordt, en
  vooral wanneer niet. Een melding die te vaak komt leert je ze wegklikken, en
  dan mis je de keer dat het ertoe doet.
  """
  use ControlPlane.DataCase, async: false

  import Swoosh.TestAssertions

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.StilleNodes
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Notifier

  setup do
    vorig = Application.get_env(:control_plane, :ops_email)
    Application.put_env(:control_plane, :ops_email, "ops@bunk.test")

    on_exit(fn ->
      case vorig do
        nil -> Application.delete_env(:control_plane, :ops_email)
        waarde -> Application.put_env(:control_plane, :ops_email, waarde)
      end
    end)

    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
      |> Repo.insert!()

    %{region: region}
  end

  defp ago(seconden),
    do: DateTime.utc_now() |> DateTime.add(-seconden, :second) |> DateTime.truncate(:second)

  defp node_met(region, status, hartslag_seconden_geleden) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: status,
      last_heartbeat_at: hartslag_seconden_geleden && ago(hartslag_seconden_geleden)
    })
    |> Repo.insert!()
  end

  defp vps_op(node, status) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: node.region_id,
      node_id: node.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: status
    })
    |> Repo.insert!()
  end

  defp gemeld?(node), do: not is_nil(Repo.get!(Node, node.id).offline_notified_at)

  test "een node die twintig minuten stil is wordt gemeld", %{region: region} do
    node = node_met(region, :offline, 1200)

    assert StilleNodes.melden() == 1

    assert_email_sent(fn email ->
      assert email.subject == "[Bunk] Node #{node.name} reageert niet meer"
      assert email.text_body =~ node.name
      assert email.text_body =~ "bunk-worker"
    end)

    assert gemeld?(node)
  end

  test "dezelfde uitval mailt maar één keer", %{region: region} do
    node = node_met(region, :offline, 1200)

    assert StilleNodes.melden() == 1
    assert StilleNodes.melden() == 0
    assert StilleNodes.melden() == 0

    # Eén mail, ook na drie rondes. Zonder dit mailt een toestand die dagen duurt
    # elke ronde opnieuw.
    assert_email_sent(subject: "[Bunk] Node #{node.name} reageert niet meer")
    refute_email_sent()
  end

  test "binnen de respijttijd wordt er niet gemeld", %{region: region} do
    # Een uitrol laat de agent op VM102 even wegvallen. Een mail per uitrol is
    # precies het soort melding dat je leert wegklikken.
    node = node_met(region, :offline, 300)

    assert StilleNodes.melden() == 0
    refute_email_sent()
    refute gemeld?(node)
  end

  test "een node die online staat wordt niet gemeld", %{region: region} do
    node = node_met(region, :online, 5)

    assert StilleNodes.melden() == 0
    refute gemeld?(node)
  end

  test "een node die nog nooit een hartslag gaf is niet weggevallen", %{region: region} do
    # Die is nooit begonnen. Een node die wacht op zijn inschrijving hoort geen
    # alarm te geven.
    node = node_met(region, :offline, nil)

    assert StilleNodes.melden() == 0
    refute gemeld?(node)
  end

  test "een tweede uitval meldt opnieuw, nadat de node tussendoor terug was", %{region: region} do
    node = node_met(region, :offline, 1200)
    assert StilleNodes.melden() == 1
    assert gemeld?(node)

    # De node komt terug.
    {:ok, _} =
      Fleet.mark_online_heartbeat(Repo.get!(Node, node.id), %{
        total_vcpu: 4,
        total_ram_mb: 8192,
        total_disk_gb: 100,
        reported_avail_vcpu: 4,
        reported_avail_ram_mb: 8192,
        reported_avail_disk_gb: 100
      })

    refute gemeld?(node)

    # En valt later opnieuw weg: dat is een nieuwe gebeurtenis.
    Repo.get!(Node, node.id)
    |> Ecto.Changeset.change(%{status: :offline, last_heartbeat_at: ago(1500)})
    |> Repo.update!()

    assert StilleNodes.melden() == 1
  end

  test "de melding noemt hoeveel actieve VPS'en erdoor geraakt worden", %{region: region} do
    node = node_met(region, :offline, 1200)
    vps_op(node, :active)
    vps_op(node, :active)
    # Een verwijderde VPS is geen klant die er last van heeft.
    vps_op(node, :deleted)

    StilleNodes.melden()

    assert_email_sent(fn email -> assert email.text_body =~ "2 actieve VPS" end)
  end

  test "een lege node meldt dat er niemand door geraakt is", %{region: region} do
    node_met(region, :offline, 1200)

    StilleNodes.melden()

    assert_email_sent(fn email ->
      assert email.text_body =~ "geen klanten door geraakt"
    end)
  end

  test "een mislukte verzending laat de node ongemarkeerd en wordt opnieuw geprobeerd", %{
    region: region
  } do
    node = node_met(region, :offline, 1200)

    # De rem op meldingen telt per onderwerp en staat op drie per uur. Daar
    # doorheen is de enige manier om een mislukte verzending na te bootsen zonder
    # de mailserver zelf kapot te maken.
    onderwerp = "Node #{node.name} reageert niet meer"
    for _ <- 1..3, do: Notifier.deliver_operational_alert(onderwerp, "vooraf")

    assert StilleNodes.melden() == 0

    # Niet gemarkeerd: een tijdelijk kapotte mailserver mag een uitval niet voor
    # altijd verzwijgen.
    refute gemeld?(node)
  end

  test "zonder operatoradres wordt er gemarkeerd in plaats van eindeloos geprobeerd", %{
    region: region
  } do
    Application.delete_env(:control_plane, :ops_email)
    node = node_met(region, :offline, 1200)

    assert StilleNodes.melden() == 0

    # Er valt niets opnieuw te proberen, want alleen een mens kan dit oplossen.
    # Zonder markering logt elke ronde dezelfde foutregel.
    assert gemeld?(node)
  end
end
