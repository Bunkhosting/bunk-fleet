defmodule ControlPlane.MachtscommandoGelijktijdigTest do
  @moduledoc """
  Tien keer tegelijk op herstarten drukken levert één herstart op.

  `in_flight?/2` keek of er al een machtscommando onderweg was en sloeg het
  inplannen dan over. Dat werkt tegen een dubbelklik en niet tegen echte
  gelijktijdigheid: tien verzoeken lezen alle tien "er loopt niets" voordat er
  één invoegt.

  Gemeten op productie met tien gelijktijdige herstarts: tien commando's
  aangemaakt, één afgerond, zes geweigerd door de agent, drie voorgoed blijven
  hangen in herlevering -- en die drie stuurden daarna elk uur een melding.
  """
  use ControlPlane.DataCase, async: false

  import Ecto.Query

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  defp draaiende_vps do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: region.id
      })
      |> Ecto.Changeset.change(%{status: :online, last_heartbeat_at: ControlPlane.Clock.now()})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "machtstest",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20,
      owner_email: "klant@voorbeeld.nl"
    })
    |> Ecto.Changeset.change(%{status: :active, node_id: node.id, provider_vm_id: "900"})
    |> Repo.insert!()
  end

  defp aantal_commandos(vps, kind) do
    Repo.one(
      from c in Command,
        where: c.vps_id == ^vps.id and c.kind == ^kind and c.status in [:pending, :delivered],
        select: count(c.id)
    )
  end

  test "twee keer herstarten achter elkaar levert één commando op" do
    vps = draaiende_vps()

    assert {:ok, %{command: %Command{}}} = Provisioning.reboot_vps(vps.id)
    assert {:ok, %{command: nil}} = Provisioning.reboot_vps(vps.id)

    assert aantal_commandos(vps, :reboot) == 1
  end

  test "de database laat er maar één door, ook als de voorwacht wordt overgeslagen" do
    vps = draaiende_vps()
    assert {:ok, %{command: %Command{}}} = Provisioning.reboot_vps(vps.id)

    # Rechtstreeks invoegen, zoals een gelijktijdig verzoek doet dat de controle
    # al voorbij was. Zonder de index zou dit gewoon lukken.
    botsing =
      Repo.insert(
        Command.changeset(%Command{}, %{
          node_id: vps.node_id,
          vps_id: vps.id,
          kind: :reboot,
          status: :pending,
          payload: %{"vm_id" => "900"}
        })
      )

    assert {:error, %Ecto.Changeset{}} = botsing
    assert aantal_commandos(vps, :reboot) == 1
  end

  test "een ander soort commando mag er wel naast" do
    vps = draaiende_vps()
    assert {:ok, %{command: %Command{}}} = Provisioning.reboot_vps(vps.id)
    assert {:ok, %{command: %Command{}}} = Provisioning.stop_vps(vps.id)

    assert aantal_commandos(vps, :reboot) == 1
    assert aantal_commandos(vps, :stop) == 1
  end
end
