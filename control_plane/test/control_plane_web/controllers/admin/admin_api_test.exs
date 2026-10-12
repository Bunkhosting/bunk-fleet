defmodule ControlPlaneWeb.Admin.AdminApiTest do
  use ControlPlaneWeb.ConnCase

  import ControlPlane.Fixtures, only: [confirmed_user_fixture: 0]

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  # Het gedeelde geheim dat /admin/v1 tot 2026-10 opende. Hier alleen nog om
  # te bewijzen dat het niets meer opent.
  @oud_geheim "test-admin-token"
  @uuid "00000000-0000-0000-0000-000000000001"

  defp create_region(_) do
    region =
      %Region{}
      |> Region.changeset(%{code: "nl-1", name: "Netherlands 1"})
      |> Repo.insert!()

    %{region: region}
  end

  defp auth(conn, token) do
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  # Elke route onder /admin/v1, zoals de router hem noemt. De laatste test in
  # "authenticatie" legt vast dat deze lijst compleet is: een nieuwe route die
  # hier ontbreekt, wordt dan niet stilletjes ongetoetst toegevoegd.
  defp routes do
    [
      {:get, "/admin/v1/regions"},
      {:post, "/admin/v1/regions"},
      {:post, "/admin/v1/enroll-tokens"},
      {:get, "/admin/v1/nodes"},
      {:post, "/admin/v1/nodes/:id/drain"},
      {:post, "/admin/v1/nodes/:id/resume"},
      {:get, "/admin/v1/vpses"},
      {:post, "/admin/v1/vpses"},
      {:delete, "/admin/v1/vpses/:id"},
      {:get, "/admin/v1/billing/usage"},
      {:get, "/admin/v1/credits"},
      {:post, "/admin/v1/credits"},
      {:get, "/admin/v1/topups"},
      {:post, "/admin/v1/topups/:id/confirm"}
    ]
  end

  # Ids die niet bestaan: de autorisatie hoort te beslissen voordat er iets
  # wordt opgezocht.
  defp request(conn, {verb, pad}) do
    pad = String.replace(pad, ":id", @uuid)

    case verb do
      :get -> get(conn, pad)
      :post -> post(conn, pad, %{})
      :delete -> delete(conn, pad)
    end
  end

  defp gebruiker(rol) do
    confirmed_user_fixture()
    |> Ecto.Changeset.change(%{role: rol})
    |> Repo.update!()
  end

  # Enrolls a node in `region` and seeds it with capacity so VPSes can be placed.
  defp enroll_node_with_capacity(region) do
    {:ok, {plaintext, _token}} =
      Enrollment.create_enroll_token(%{
        region_id: region.id,
        ttl_seconds: 3600
      })

    {:ok, %{node: node}} =
      Enrollment.enroll(plaintext, %{hypervisor: "proxmox", agent_version: "1.2.3"})

    node
    |> Ecto.Changeset.change(
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000
    )
    |> Repo.update!()
  end

  # Creates a VPS and drives it to :active so it has a provider_vm_id (the
  # precondition for deletion).
  defp active_vps(region) do
    {:ok, %{vps: vps, command: command}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: "vps-test",
        vcpu: 2,
        ram_mb: 2048,
        disk_gb: 20,
        owner_email: "ops@bunkhosting.nl",
        template_id: 9000
      })

    {:ok, _command} =
      Provisioning.apply_result(command, %{
        "status" => "done",
        "vm_id" => "10101",
        "ip" => "10.10.0.10",
        "error" => nil
      })

    Repo.get!(Vps, vps.id)
  end

  describe "authenticatie" do
    test "zonder iets is het 401", %{conn: conn} do
      for route <- routes() do
        assert %{status: 401} = request(conn, route), "anoniem bereikte #{inspect(route)}"
      end
    end

    # Het geheim staat hier bewust ook in de configuratie, zoals ADMIN_TOKEN nog
    # in .env.prod kan staan. Leest iemand het ooit weer, dan wordt dit rood.
    test "het oude geheim opent niets, ook niet als het nog is ingesteld", %{conn: conn} do
      Application.put_env(:control_plane, :admin_token, @oud_geheim)
      on_exit(fn -> Application.delete_env(:control_plane, :admin_token) end)

      oud = auth(conn, @oud_geheim)

      for route <- routes() do
        resp = request(oud, route)

        assert resp.status == 401,
               "het oude geheim bereikte #{inspect(route)} met #{resp.status}"

        assert json_response(resp, 401) == %{"error" => "unauthorized"}
      end
    end

    # 403 en geen 401: de sessie is echt, alleen de rol ontbreekt. Daarmee is
    # ook bewezen dat dit verzoek voorbij de authenticatie kwam.
    test "een gewone gebruiker krijgt 403", %{conn: conn} do
      klant = met_sessie(conn, gebruiker(:user))

      for route <- routes() do
        resp = request(klant, route)
        assert resp.status == 403, "een :user bereikte #{inspect(route)} met #{resp.status}"
        assert json_response(resp, 403) == %{"error" => "forbidden"}
      end
    end

    test "een beheerder zonder tweede factor krijgt 403", %{conn: conn} do
      resp = conn |> met_sessie(gebruiker(:admin)) |> get(~p"/admin/v1/regions")

      assert %{"error" => "admin_mfa_required"} = json_response(resp, 403)
    end

    test "een beheerderssessie werkt", %{conn: conn} do
      %{region: region} = create_region(%{})
      {beheerder, _gebruiker} = als_beheerder(conn)

      body = beheerder |> get(~p"/admin/v1/regions") |> json_response(200)

      assert Enum.any?(body["regions"], &(&1["code"] == region.code))
    end

    test "een beheerder wordt door geen enkele route geweigerd", %{conn: conn} do
      {beheerder, _gebruiker} = als_beheerder(conn)

      for route <- routes() do
        resp = request(beheerder, route)

        refute resp.status in [401, 403],
               "de beheerder werd geweigerd op #{inspect(route)} met #{resp.status}"
      end
    end

    test "de routelijst is compleet" do
      in_router =
        ControlPlaneWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.filter(&String.starts_with?(&1.path, "/admin/v1"))
        |> Enum.map(&{&1.verb, &1.path})
        |> MapSet.new()

      assert in_router == MapSet.new(routes())
    end
  end

  describe "met een beheerderssessie" do
    setup %{conn: conn} do
      {conn, _beheerder} = als_beheerder(conn)
      {:ok, conn: conn}
    end

    test "creates a region", %{conn: conn} do
      conn =
        post(conn, ~p"/admin/v1/regions", %{
          "code" => "de-1",
          "name" => "Germany 1"
        })

      assert %{"region" => region} = json_response(conn, 201)
      assert region["code"] == "de-1"
      assert region["name"] == "Germany 1"
      assert is_binary(region["id"])
      assert Repo.get_by(Region, code: "de-1")
    end

    test "lists regions", %{conn: conn} do
      %{region: region} = create_region(%{})

      conn = get(conn, ~p"/admin/v1/regions")

      assert %{"regions" => regions} = json_response(conn, 200)
      assert Enum.any?(regions, &(&1["code"] == region.code))
    end

    test "creates an enroll token and returns plaintext + install string", %{conn: conn} do
      %{region: region} = create_region(%{})

      conn =
        post(conn, ~p"/admin/v1/enroll-tokens", %{
          "region_code" => region.code,
          "ttl_seconds" => 3600
        })

      assert %{
               "enroll_token" => enroll_token,
               "install" => install,
               "region" => region_code
             } = json_response(conn, 201)

      assert is_binary(enroll_token)
      assert region_code == region.code
      # The wizard, not a container: only an agent installed on the hypervisor
      # host can configure the customer bridge it is assigned.
      assert install =~ "/install.sh"
      assert install =~ "--token " <> enroll_token
      refute install =~ "docker run"
    end

    test "lists nodes (empty is ok)", %{conn: conn} do
      conn = get(conn, ~p"/admin/v1/nodes")
      assert %{"nodes" => nodes} = json_response(conn, 200)
      assert nodes == []
    end

    test "creating a vps with no nodes available returns 409 no_capacity", %{conn: conn} do
      %{region: region} = create_region(%{})

      conn =
        post(conn, ~p"/admin/v1/vpses", %{
          "region_code" => region.code,
          "name" => "vps-test",
          "vcpu" => 2,
          "ram_mb" => 2048,
          "disk_gb" => 20,
          "owner_email" => "ops@bunkhosting.nl"
        })

      assert %{"error" => "no_capacity"} = json_response(conn, 409)
    end

    test "deletes a vps, returning 202 and moving it to :deleting", %{conn: conn} do
      %{region: region} = create_region(%{})
      _node = enroll_node_with_capacity(region)
      vps = active_vps(region)

      conn = delete(conn, ~p"/admin/v1/vpses/#{vps.id}")

      assert %{"vps" => body} = json_response(conn, 202)
      assert body["id"] == vps.id
      assert body["status"] == "deleting"

      assert Repo.get!(Vps, vps.id).status == :deleting
    end

    test "deleting an unknown vps returns 404", %{conn: conn} do
      conn = delete(conn, ~p"/admin/v1/vpses/#{Ecto.UUID.generate()}")
      assert %{"error" => "not_found"} = json_response(conn, 404)
    end
  end
end
