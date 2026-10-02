defmodule ControlPlaneWeb.HeartbeatNetwerknotitieTest do
  @moduledoc """
  Wat een node over zijn eigen VPS-netwerk meldt, en wat het control plane
  daarmee doet.

  Een node kon er van buiten volkomen gezond uitzien -- hartslag, capaciteit,
  API-rechten -- en toch niet bij de VPS'en komen die hij zelf draait. De
  webterminal loopt via de agent, dus dan viel die zonder uitleg dicht. De agent
  wist dat wel, maar zei het alleen in een logbestand op de node.

  Drie dingen moeten hier waar zijn:

    * de notitie komt aan en is zichtbaar voor degene die de node beheert;
    * een notitie houdt de node NIET uit de verkoop -- het is een vermoeden, en
      een vals alarm dat een gezonde node dichtzet kost omzet;
    * hij verdwijnt zodra de agent hem weglaat, anders blijft hij staan voor een
      probleem dat al is opgelost.
  """
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  setup do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
      |> Repo.insert!()

    {:ok, {plaintext, _token}} =
      Enrollment.create_enroll_token(%{region_id: region.id, ttl_seconds: 3600})

    {:ok, %{node: node, agent_token: agent_token}} =
      Enrollment.enroll(plaintext, %{hypervisor: "proxmox", agent_version: "1.2.3"})

    %{node: node, agent_token: agent_token}
  end

  defp heartbeat(conn, node, token, extra) do
    body =
      Map.merge(
        %{
          "node_id" => node.id,
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "total_vcpu" => 8,
          "avail_vcpu" => 8,
          "total_ram_mb" => 16_384,
          "avail_ram_mb" => 16_384,
          "total_disk_gb" => 500,
          "avail_disk_gb" => 500
        },
        extra
      )

    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(~p"/v1/heartbeat", body)
  end

  test "een notitie komt aan en laat de capaciteit staan", %{
    conn: conn,
    node: node,
    agent_token: token
  } do
    notitie = "bridge vmbr2 heeft geen adres in 172.16.22.0/24"

    assert json_response(heartbeat(conn, node, token, %{"network_note" => notitie}), 200)

    node = Repo.get!(Node, node.id)
    assert node.network_note == notitie
    # De kern: een notitie is geen storing. Zou dit op nul vallen, dan zet elk
    # vals alarm een gezonde node uit de verkoop.
    assert is_nil(node.capacity_error)
    assert node.reported_avail_ram_mb == 16_384
  end

  test "een heartbeat zonder notitie haalt een eerdere weg", %{
    conn: conn,
    node: node,
    agent_token: token
  } do
    heartbeat(conn, node, token, %{"network_note" => "iets mis"})
    assert Repo.get!(Node, node.id).network_note == "iets mis"

    # De agent laat het veld weg zodra het is rechtgezet.
    heartbeat(build_conn(), node, token, %{})

    assert is_nil(Repo.get!(Node, node.id).network_note)
  end

  test "een notitie en een capaciteitsfout bestaan naast elkaar", %{
    conn: conn,
    node: node,
    agent_token: token
  } do
    # Een vaststelling (capaciteitsfout) en een vermoeden (notitie) zijn twee
    # verschillende dingen en moeten allebei aankomen.
    heartbeat(conn, node, token, %{
      "capacity_error" => "kan gateway-adres niet zetten",
      "network_note" => "VPS-netwerk niet opgezet"
    })

    node = Repo.get!(Node, node.id)
    assert node.capacity_error == "kan gateway-adres niet zetten"
    assert node.network_note == "VPS-netwerk niet opgezet"
  end

  test "een te lange notitie wordt ingekort en laat de heartbeat niet afketsen", %{
    conn: conn,
    node: node,
    agent_token: token
  } do
    # Een agent is de minst betrouwbare invoer die dit systeem kent. Wordt een
    # te lange melding geweigerd in plaats van ingekort, dan valt de hele
    # heartbeat om en staat de node dood in het paneel om een foutmelding die te
    # lang was.
    lang = String.duplicate("x", 5_000)

    assert json_response(heartbeat(conn, node, token, %{"network_note" => lang}), 200)

    assert String.length(Repo.get!(Node, node.id).network_note) <= 240
  end

  test "controletekens in een notitie komen niet in het paneel", %{
    conn: conn,
    node: node,
    agent_token: token
  } do
    heartbeat(conn, node, token, %{"network_note" => "regel een\nregel twee\e[31m"})

    notitie = Repo.get!(Node, node.id).network_note
    refute notitie =~ ~r/[[:cntrl:]]/u
  end
end
