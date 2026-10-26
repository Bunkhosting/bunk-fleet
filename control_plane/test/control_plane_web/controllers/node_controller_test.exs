defmodule ControlPlaneWeb.NodeControllerTest do
  @moduledoc """
  De node-endpoints via HTTP, niet via de context.

  Deze routes staan bewust niet onder `/beheer` — de eigenaar van een node is
  niet per se beheerder van het platform — en vallen daarmee buiten de test die
  eist dat elke beheerroute gedekt is. Zonder deze tests wordt de bedrading
  (router, plug, controller) dus door niets bewaakt, terwijl juist dáár een slot
  vergeten wordt.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp gebruiker(rol \\ :user) do
    email = "#{rol}-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    if rol == :admin, do: elem(Accounts.update_user_role(u, :admin), 1), else: u
  end

  defp ingelogd(conn, user) do
    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp fleet_node(owner) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now(),
      owner_id: owner && owner.id
    })
    |> Repo.insert!()
  end

  describe "GET /api/v1/nodes" do
    test "toont alleen de eigen nodes", %{conn: conn} do
      ik = gebruiker()
      ander = gebruiker()
      mijn = fleet_node(ik)
      _van_een_ander = fleet_node(ander)

      resp = conn |> ingelogd(ik) |> get(~p"/api/v1/nodes") |> json_response(200)

      assert [%{"id" => id}] = resp["nodes"]
      assert id == mijn.id
    end

    test "zonder sessie: 401", %{conn: conn} do
      assert conn |> get(~p"/api/v1/nodes") |> json_response(401)
    end

    test "een beheerder ziet niet automatisch andermans nodes", %{conn: conn} do
      # Beheerder zijn geeft toegang tot het beheerpaneel, niet tot de instellingen
      # van andermans hardware.
      beheerder = gebruiker(:admin)
      _van_een_ander = fleet_node(gebruiker())

      resp = conn |> ingelogd(beheerder) |> get(~p"/api/v1/nodes") |> json_response(200)

      assert resp["nodes"] == []
    end
  end

  describe "PATCH /api/v1/nodes/:id/settings" do
    test "de eigenaar wijzigt zijn instellingen", %{conn: conn} do
      ik = gebruiker()
      n = fleet_node(ik)

      resp =
        conn
        |> ingelogd(ik)
        |> patch(~p"/api/v1/nodes/#{n.id}/settings", %{"offer_ram_mb" => 3584})
        |> json_response(200)

      assert resp["node"]["settings"]["offer_ram_mb"] == 3584
    end

    test "andermans node geeft 404 en geen 403", %{conn: conn} do
      # Dat een node bestaat is zelf al iets wat een vreemde niet hoeft te weten.
      n = fleet_node(gebruiker())

      conn
      |> ingelogd(gebruiker())
      |> patch(~p"/api/v1/nodes/#{n.id}/settings", %{"offer_ram_mb" => 1})
      |> json_response(404)

      assert is_nil(Repo.get!(Node, n.id).offer_ram_mb)
    end

    test "een beheerder mag er ook niet bij", %{conn: conn} do
      n = fleet_node(gebruiker())

      conn
      |> ingelogd(gebruiker(:admin))
      |> patch(~p"/api/v1/nodes/#{n.id}/settings", %{"offer_ram_mb" => 1})
      |> json_response(404)
    end

    test "een ongeldig naampatroon geeft 422 met de reden", %{conn: conn} do
      ik = gebruiker()
      n = fleet_node(ik)

      resp =
        conn
        |> ingelogd(ik)
        |> patch(~p"/api/v1/nodes/#{n.id}/settings", %{"guest_name_pattern" => "{naam}"})
        |> json_response(422)

      assert resp["error"] == "invalid_settings"
      assert [melding | _] = resp["details"]["guest_name_pattern"]
      assert melding =~ "{id}"
    end

    test "zonder sessie: 401", %{conn: conn} do
      n = fleet_node(gebruiker())

      assert conn
             |> patch(~p"/api/v1/nodes/#{n.id}/settings", %{"offer_ram_mb" => 1})
             |> json_response(401)
    end
  end

  describe "POST /api/v1/nodes/:id/region" do
    test "de eigenaar typt een plaats die nog niet bestaat", %{conn: conn} do
      ik = gebruiker()
      n = fleet_node(ik)

      resp =
        conn
        |> ingelogd(ik)
        |> post(~p"/api/v1/nodes/#{n.id}/region", %{"region_name" => "Eindhoven"})
        |> json_response(200)

      assert resp["node"]["region"]["name"] == "Eindhoven"
      assert resp["node"]["region"]["code"] == "eindhoven"
      assert Repo.get!(Node, n.id).region_id == resp["node"]["region"]["id"]
    end

    test "een vreemde krijgt 404 en maakt geen locatie aan", %{conn: conn} do
      n = fleet_node(gebruiker())

      conn
      |> ingelogd(gebruiker())
      |> post(~p"/api/v1/nodes/#{n.id}/region", %{"region_name" => "Rotterdam"})
      |> json_response(404)

      assert Repo.aggregate(from(r in Region, where: r.name == "Rotterdam"), :count) == 0
    end

    test "een lege naam geeft 422", %{conn: conn} do
      ik = gebruiker()
      n = fleet_node(ik)

      resp =
        conn
        |> ingelogd(ik)
        |> post(~p"/api/v1/nodes/#{n.id}/region", %{"region_name" => " "})
        |> json_response(422)

      assert resp["error"] == "invalid_region"
    end

    test "een bestaande locatie mag ook op id", %{conn: conn} do
      # Het dashboard stuurt de naam, maar het id blijft werken: dat wijst er
      # precies een aan, zonder te kunnen verschuiven door een hernoeming.
      ik = gebruiker()
      n = fleet_node(ik)
      doel = %Region{} |> Region.changeset(%{code: "ams-9", name: "Amsterdam"}) |> Repo.insert!()

      conn
      |> ingelogd(ik)
      |> post(~p"/api/v1/nodes/#{n.id}/region", %{"region_id" => doel.id})
      |> json_response(200)

      assert Repo.get!(Node, n.id).region_id == doel.id
    end

    test "zonder sessie: 401", %{conn: conn} do
      n = fleet_node(gebruiker())

      assert conn
             |> post(~p"/api/v1/nodes/#{n.id}/region", %{"region_name" => "Eindhoven"})
             |> json_response(401)
    end
  end

  describe "POST /api/v1/nodes/:id/owner" do
    test "de eigenaar draagt over op e-mailadres", %{conn: conn} do
      ik = gebruiker()
      opvolger = gebruiker()
      n = fleet_node(ik)

      conn
      |> ingelogd(ik)
      |> post(~p"/api/v1/nodes/#{n.id}/owner", %{"owner_email" => opvolger.email})
      |> json_response(200)

      assert Repo.get!(Node, n.id).owner_id == opvolger.id
    end

    test "een beheerder wijst een node zonder eigenaar hier NIET toe", %{conn: conn} do
      # Dat hoort in het beheerpaneel, achter tweede factor en auditlog. Deze
      # route kende geen van beide, en een beheerderssessie zonder tweede factor
      # kon hier zo een node claimen.
      beheerder = gebruiker(:admin)
      nieuwe = gebruiker()
      n = fleet_node(nil)

      conn
      |> ingelogd(beheerder)
      |> post(~p"/api/v1/nodes/#{n.id}/owner", %{"owner_email" => nieuwe.email})
      |> json_response(404)

      assert is_nil(Repo.get!(Node, n.id).owner_id)
    end

    test "een beheerder kan een node mét eigenaar niet overnemen", %{conn: conn} do
      beheerder = gebruiker(:admin)
      eigenaar = gebruiker()
      n = fleet_node(eigenaar)

      conn
      |> ingelogd(beheerder)
      |> post(~p"/api/v1/nodes/#{n.id}/owner", %{"owner_email" => beheerder.email})
      |> json_response(404)

      assert Repo.get!(Node, n.id).owner_id == eigenaar.id
    end

    test "een onbekend adres geeft 422 en verandert niets", %{conn: conn} do
      ik = gebruiker()
      n = fleet_node(ik)

      resp =
        conn
        |> ingelogd(ik)
        |> post(~p"/api/v1/nodes/#{n.id}/owner", %{"owner_email" => "bestaatniet@bunk.test"})
        |> json_response(422)

      assert resp["error"] == "unknown_user"
      assert Repo.get!(Node, n.id).owner_id == ik.id
    end

    test "een leeg adres maakt de node eigenaarloos", %{conn: conn} do
      ik = gebruiker()
      n = fleet_node(ik)

      conn
      |> ingelogd(ik)
      |> post(~p"/api/v1/nodes/#{n.id}/owner", %{"owner_email" => ""})
      |> json_response(200)

      assert is_nil(Repo.get!(Node, n.id).owner_id)
    end
  end
end
