defmodule ControlPlaneWeb.Admin.PanelRegionsTest do
  @moduledoc """
  De locaties zoals het beheerpaneel ze aanmaakt en wijzigt.

  De autorisatie staat al in `PanelAuthzTest`; hier gaat het om wat de rijen
  zeggen. Het paneel vertrouwt op het antwoord van een wijziging en voegt dat
  samen met de rij die het al toonde, dus een veld dat "niet opgevraagd"
  betekent maar als getal terugkomt liegt zodra het op het scherm staat.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures, only: [with_second_factor: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  setup %{conn: conn} do
    email = "beheer-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u = u |> Ecto.Changeset.change(%{role: :admin}) |> Repo.update!() |> with_second_factor()

    token =
      u |> Accounts.generate_user_session_token(mfa: true) |> Base.url_encode64(padding: false)

    %{conn: put_req_header(conn, "authorization", "Bearer " <> token)}
  end

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Regio #{code}"}) |> Repo.insert!()
  end

  defp fleet_node(region) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{status: :online, last_heartbeat_at: ControlPlane.Clock.now()})
    |> Repo.insert!()
  end

  defp rij(resp, region), do: Enum.find(resp["regions"], &(&1["id"] == region.id))

  test "de lijst toont per locatie hoeveel nodes erin staan", %{conn: conn} do
    vol = regio()
    leeg = regio()
    fleet_node(vol)

    resp = conn |> get(~p"/api/v1/beheer/regions") |> json_response(200)

    assert rij(resp, vol)["node_count"] == 1
    assert rij(resp, leeg)["node_count"] == 0
    assert rij(resp, leeg)["enabled"] == true
  end

  test "aanmaken geeft de nieuwe locatie terug", %{conn: conn} do
    code = "nl-#{System.unique_integer([:positive])}"

    resp =
      conn
      |> post(~p"/api/v1/beheer/regions", %{"code" => code, "name" => "Amsterdam"})
      |> json_response(201)

    assert resp["region"]["code"] == code
    assert resp["region"]["node_count"] == 0
  end

  test "een code die al bestaat geeft 422 met de reden", %{conn: conn} do
    r = regio()

    resp =
      conn
      |> post(~p"/api/v1/beheer/regions", %{"code" => r.code, "name" => "Dubbel"})
      |> json_response(422)

    assert resp["error"] == "region_code_taken"
  end

  test "sluiten laat het aantal nodes staan", %{conn: conn} do
    # Dit is de fout die deze test bewaakt: het antwoord vulde hier een nul in
    # omdat er niet geteld was, waarna de locatie in het paneel als leeg op het
    # scherm kwam terwijl er nodes in stonden.
    r = regio()
    fleet_node(r)
    fleet_node(r)

    resp =
      conn
      |> patch(~p"/api/v1/beheer/regions/#{r.id}", %{"enabled" => false})
      |> json_response(200)

    assert resp["region"]["enabled"] == false
    assert resp["region"]["node_count"] == 2
  end

  test "naam en code wijzigen kan in één keer", %{conn: conn} do
    r = regio()

    resp =
      conn
      |> patch(~p"/api/v1/beheer/regions/#{r.id}", %{"name" => "Amsterdam", "code" => "ams-7"})
      |> json_response(200)

    assert resp["region"]["name"] == "Amsterdam"
    assert resp["region"]["code"] == "ams-7"
  end

  test "een bezette code en een onmogelijke code zeggen niet hetzelfde", %{conn: conn} do
    # Ze vragen om iets anders van degene die het intypt: een andere code kiezen,
    # of hem anders schrijven. Eén foutcode zou hem laten raden welke van de twee.
    bezet = regio()
    r = regio()

    assert conn
           |> patch(~p"/api/v1/beheer/regions/#{r.id}", %{"code" => bezet.code})
           |> json_response(422)
           |> Map.get("error") == "region_code_taken"

    assert conn
           |> patch(~p"/api/v1/beheer/regions/#{r.id}", %{"code" => "niet zo"})
           |> json_response(422)
           |> Map.get("error") == "invalid_region_code"
  end

  test "een locatie die niet bestaat geeft 404, ook als de id onzin is", %{conn: conn} do
    assert conn
           |> patch(~p"/api/v1/beheer/regions/#{Ecto.UUID.generate()}", %{"name" => "X"})
           |> json_response(404)

    assert conn
           |> patch(~p"/api/v1/beheer/regions/geen-uuid", %{"name" => "X"})
           |> json_response(404)
  end
end
