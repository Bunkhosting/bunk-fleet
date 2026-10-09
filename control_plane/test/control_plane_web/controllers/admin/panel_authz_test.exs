defmodule ControlPlaneWeb.Admin.PanelAuthzTest do
  @moduledoc """
  The authorization boundary around /api/v1/beheer/*.

  Everything behind this prefix reads or changes other people's accounts, VPSes
  and nodes. There is exactly one thing standing in front of it — an authenticated
  session whose user has role `:admin` — so every route is asserted against all
  three callers a request can come from, and the list is asserted to be complete:
  a route added to the scope without a case here fails the last test in this file.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures, only: [with_second_factor: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.User
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  alias ControlPlane.Repo

  @password "test-only-password-4f2b9c1e"
  @uuid "00000000-0000-0000-0000-000000000001"

  defp user_fixture(role) do
    email = "#{role}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    gebruiker = user |> Ecto.Changeset.change(%{role: role}) |> Repo.update!()

    # Een beheerder zonder tweede factor strandt op `RequireAdminMfa` en zou elke
    # route hier 403 laten geven -- dan test dit bestand die ene drempel in
    # plaats van de autorisatie erachter. Dat de drempel er is, staat in
    # `BeheerMfaTest`.
    if role == :admin, do: with_second_factor(gebruiker), else: gebruiker
  end

  defp authed(conn, %User{} = user) do
    token =
      user |> Accounts.generate_user_session_token(mfa: true) |> Base.url_encode64(padding: false)

    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  # Every route in the /api/v1/beheer scope. Ids are deliberately non-existent:
  # authorization has to be decided before the row is looked up, so a forbidden
  # caller can't use a 404 to learn which ids are real.
  defp routes do
    [
      {:get, "/api/v1/beheer/stats"},
      {:get, "/api/v1/beheer/metrics"},
      {:get, "/api/v1/beheer/omzet"},
      {:post, "/api/v1/beheer/enroll-tokens"},
      {:get, "/api/v1/beheer/regions"},
      {:post, "/api/v1/beheer/regions"},
      {:patch, "/api/v1/beheer/regions/#{@uuid}"},
      {:delete, "/api/v1/beheer/regions/#{@uuid}"},
      {:get, "/api/v1/beheer/users"},
      {:get, "/api/v1/beheer/users/#{@uuid}"},
      {:get, "/api/v1/beheer/subscriptions"},
      {:get, "/api/v1/beheer/commands"},
      {:patch, "/api/v1/beheer/users/#{@uuid}"},
      {:post, "/api/v1/beheer/users/#{@uuid}/credit"},
      {:delete, "/api/v1/beheer/users/#{@uuid}"},
      {:get, "/api/v1/beheer/vpses"},
      {:post, "/api/v1/beheer/vpses/#{@uuid}/start"},
      {:post, "/api/v1/beheer/vpses/#{@uuid}/stop"},
      {:delete, "/api/v1/beheer/vpses/#{@uuid}"},
      {:get, "/api/v1/beheer/nodes"},
      {:post, "/api/v1/beheer/nodes/#{@uuid}/drain"},
      {:post, "/api/v1/beheer/nodes/#{@uuid}/resume"},
      {:delete, "/api/v1/beheer/nodes/#{@uuid}"}
    ]
  end

  defp request(conn, {verb, path}) do
    case verb do
      :get -> get(conn, path)
      :post -> post(conn, path, %{})
      :patch -> patch(conn, path, %{})
      :delete -> delete(conn, path)
    end
  end

  test "no session reaches nothing", %{conn: conn} do
    for route <- routes() do
      assert %{status: 401} = request(conn, route), "anonymous reached #{inspect(route)}"
    end
  end

  test "a signed-in customer reaches nothing", %{conn: conn} do
    customer = authed(conn, user_fixture(:user))

    for route <- routes() do
      resp = request(customer, route)

      assert resp.status == 403, "a :user reached #{inspect(route)} with #{resp.status}"
      assert json_response(resp, 403) == %{"error" => "forbidden"}
    end
  end

  test "a forged role in the request body changes nothing", %{conn: conn} do
    # The role is read off the session's user row, never off the request.
    customer = user_fixture(:user)

    resp =
      conn
      |> authed(customer)
      |> post("/api/v1/beheer/users/#{@uuid}/credit", %{"role" => "admin", "amount_cents" => 500})

    assert resp.status == 403
  end

  test "an admin is not blocked by the boundary", %{conn: conn} do
    admin = authed(conn, user_fixture(:admin))

    for route <- routes() do
      resp = request(admin, route)

      refute resp.status in [401, 403],
             "the admin was refused #{inspect(route)} with #{resp.status}"
    end
  end

  test "a demoted admin loses access with their next request", %{conn: conn} do
    admin = user_fixture(:admin)
    signed_in = authed(conn, admin)

    assert %{status: 200} = get(signed_in, "/api/v1/beheer/stats")

    admin |> Ecto.Changeset.change(%{role: :user}) |> Repo.update!()

    # Same token, same session: the role is re-read per request, so revoking it
    # does not depend on the session expiring.
    assert %{status: 403} = get(authed(conn, admin), "/api/v1/beheer/stats")
  end

  test "the customer API stays open to the same customer", %{conn: conn} do
    # Guards against fixing a 403 by moving the plug somewhere it blocks too much.
    customer = authed(conn, user_fixture(:user))

    assert %{status: 200} = get(customer, "/api/v1/vpses")
  end

  describe "DELETE /api/v1/beheer/users/:id" do
    test "verwijdert een account zonder administratie", %{conn: conn} do
      admin = user_fixture(:admin)
      # Een verse registratie heeft nog geen grootboek: de aanmeldbonus volgt pas
      # op de bevestiging. Dan valt er niets te bewaren.
      slachtoffer = user_fixture(:user)

      resp =
        conn
        |> authed(admin)
        |> delete("/api/v1/beheer/users/#{slachtoffer.id}")
        |> json_response(200)

      assert resp["result"] == "deleted"
      assert is_nil(Repo.get(User, slachtoffer.id))
    end

    test "anonimiseert een account met een administratie", %{conn: conn} do
      # De aanmeldbonus komt pas bij het bevestigen van het account, dus een
      # verse registratie heeft nog niets. Hier zetten we er wel iets neer: dat
      # is het geval waarin de facturen en het grootboek moeten blijven staan.
      admin = user_fixture(:admin)
      klant = user_fixture(:user)
      {:ok, _} = ControlPlane.Credits.add_entry(klant.id, 5000, "topup", "test")

      resp =
        conn
        |> authed(admin)
        |> delete("/api/v1/beheer/users/#{klant.id}")
        |> json_response(200)

      assert resp["result"] == "anonymised"
      bewaard = Repo.get!(User, klant.id)
      refute bewaard.email == klant.email
      assert bewaard.email =~ "@verwijderd.invalid"
    end

    test "weigert jezelf te verwijderen", %{conn: conn} do
      admin = user_fixture(:admin)

      resp =
        conn
        |> authed(admin)
        |> delete("/api/v1/beheer/users/#{admin.id}")
        |> json_response(422)

      assert resp["error"] == "cannot_delete_self"
      assert Repo.get!(User, admin.id).email == admin.email
    end

    test "een gewone gebruiker mag het niet", %{conn: conn} do
      klant = user_fixture(:user)
      doelwit = user_fixture(:user)

      conn |> authed(klant) |> delete("/api/v1/beheer/users/#{doelwit.id}") |> json_response(403)

      assert Repo.get!(User, doelwit.id).email == doelwit.email
    end
  end

  test "every /beheer route in the router is covered above" do
    declared =
      ControlPlaneWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v1/beheer"))
      |> Enum.map(fn r -> {r.verb, r.path} end)
      |> MapSet.new()

    tested =
      routes()
      |> Enum.map(fn {verb, path} -> {verb, String.replace(path, @uuid, ":id")} end)
      |> MapSet.new()

    assert MapSet.difference(declared, tested) |> MapSet.to_list() == [],
           "a /beheer route exists that this file does not check"
  end

  test "an admin sees other people's VPSes and a customer does not", %{conn: conn} do
    owner = user_fixture(:user)
    stranger = user_fixture(:user)
    vps = vps_fixture(owner)

    listed =
      conn
      |> authed(user_fixture(:admin))
      |> get("/api/v1/beheer/vpses")
      |> json_response(200)
      |> Map.fetch!("vpses")
      |> Enum.map(& &1["id"])

    assert vps.id in listed

    # The customer API is owner-scoped, so the stranger sees an empty list rather
    # than someone else's machine.
    stranger_sees =
      conn
      |> authed(stranger)
      |> get("/api/v1/vpses")
      |> json_response(200)
      |> Map.fetch!("vpses")
      |> Enum.map(& &1["id"])

    refute vps.id in stranger_sees
  end

  defp vps_fixture(owner) do
    region =
      %Region{}
      |> Region.changeset(%{
        code: "r-#{System.unique_integer([:positive])}",
        name: "Region"
      })
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      owner_id: owner.id,
      owner_email: owner.email,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :active
    })
    |> Repo.insert!()
  end
end
