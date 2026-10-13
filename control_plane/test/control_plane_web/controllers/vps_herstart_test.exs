defmodule ControlPlaneWeb.VpsHerstartTest do
  @moduledoc """
  Een VPS herstarten.

  Er was start en stop, maar geen herstart -- de knop die een klant het vaakst
  zoekt. Wat hier vastligt is vooral wat het níét is: geen reset (dat is de
  stekker eruit trekken bij iemands schijf) en geen verkapte start van een
  machine die uit staat.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Provisioning.Power
  alias ControlPlane.Repo

  defp gebruiker do
    email = "herstart-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp ingelogd(conn, user) do
    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp vps(user, status) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: region.id
      })
      |> Ecto.Changeset.change(%{status: :online, last_heartbeat_at: Clock.now()})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20
    })
    |> Ecto.Changeset.change(%{
      status: status,
      provider_vm_id: "2001",
      node_id: node.id,
      owner_id: user.id
    })
    |> Repo.insert!()
  end

  test "een draaiende VPS krijgt een herstartcommando", %{conn: conn} do
    u = gebruiker()
    v = vps(u, :active)

    conn |> ingelogd(u) |> post(~p"/api/v1/vpses/#{v.id}/reboot") |> json_response(200)

    assert Repo.exists?(from c in Command, where: c.vps_id == ^v.id and c.kind == :reboot)
  end

  test "de VPS blijft ondertussen actief", %{conn: conn} do
    # Er is geen moment waarop hij uit staat in de zin die het paneel bedoelt.
    # Een verzonnen tussenstand zou elke andere actie blokkeren zolang de agent
    # niet terugmeldt.
    u = gebruiker()
    v = vps(u, :active)

    conn |> ingelogd(u) |> post(~p"/api/v1/vpses/#{v.id}/reboot") |> json_response(200)

    assert Repo.get!(Vps, v.id).status == :active
  end

  test "een gestopte VPS wordt niet stiekem gestart", %{conn: conn} do
    # "Herstart" op een machine die uit staat betekent dat de aanvrager denkt
    # dat hij draait. Daar iets anders van maken verbergt die vergissing.
    u = gebruiker()
    v = vps(u, :stopped)

    resp = conn |> ingelogd(u) |> post(~p"/api/v1/vpses/#{v.id}/reboot") |> json_response(409)

    assert resp["error"] == "invalid_status_stopped"
    refute Repo.exists?(from c in Command, where: c.vps_id == ^v.id and c.kind == :reboot)
  end

  test "andermans VPS geeft 404 en geen commando", %{conn: conn} do
    v = vps(gebruiker(), :active)

    conn |> ingelogd(gebruiker()) |> post(~p"/api/v1/vpses/#{v.id}/reboot") |> json_response(404)

    refute Repo.exists?(from c in Command, where: c.vps_id == ^v.id and c.kind == :reboot)
  end

  test "zonder sessie: 401", %{conn: conn} do
    v = vps(gebruiker(), :active)

    assert conn |> post(~p"/api/v1/vpses/#{v.id}/reboot") |> json_response(401)
  end

  test "een geslaagde herstart laat de VPS draaien", %{conn: _conn} do
    # Het resultaat van de agent mag de status niet per ongeluk ergens anders
    # heen zetten: een herstart eindigt waar hij begon.
    u = gebruiker()
    v = vps(u, :active)

    {:ok, %{command: cmd}} = Power.reboot_vps(v.id)
    {:ok, _} = Provisioning.apply_result(cmd, %{"status" => "done", "vm_id" => "2001"})

    assert Repo.get!(Vps, v.id).status == :active
  end
end
