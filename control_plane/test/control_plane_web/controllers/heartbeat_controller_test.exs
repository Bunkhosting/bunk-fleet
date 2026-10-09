defmodule ControlPlaneWeb.HeartbeatControllerTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp create_region(_) do
    region =
      %Region{}
      |> Region.changeset(%{code: "nl-1", name: "Netherlands 1"})
      |> Repo.insert!()

    %{region: region}
  end

  # Enrolls a node end-to-end and returns its id plus the plaintext agent token.
  defp enroll_node(region) do
    {:ok, {plaintext, _token}} =
      Enrollment.create_enroll_token(%{
        region_id: region.id,
        ttl_seconds: 3600
      })

    {:ok, %{node: node, agent_token: agent_token}} =
      Enrollment.enroll(plaintext, %{hypervisor: "proxmox", agent_version: "1.2.3"})

    %{node: node, agent_token: agent_token}
  end

  setup [:create_region]

  describe "POST /v1/heartbeat" do
    test "valid bearer returns the settings and updates node totals and status", %{
      conn: conn,
      region: region
    } do
      %{node: node, agent_token: agent_token} = enroll_node(region)

      body = %{
        "node_id" => node.id,
        "at" => DateTime.to_iso8601(DateTime.utc_now()),
        "total_vcpu" => 32,
        "avail_vcpu" => 16,
        "total_ram_mb" => 65_536,
        "avail_ram_mb" => 32_768,
        "total_disk_gb" => 1000,
        "avail_disk_gb" => 500
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", body)

      assert json_response(conn, 200)

      updated = Repo.get!(Node, node.id)
      assert updated.total_vcpu == 32
      assert updated.total_ram_mb == 65_536
      assert updated.total_disk_gb == 1000
      assert updated.status == :online
      refute is_nil(updated.last_heartbeat_at)
    end

    test "een agent zonder zicht op zijn hypervisor blijft online, met de reden", %{
      conn: conn,
      region: region
    } do
      # Dit is het geval waarvoor dit bestaat. Tot nu toe stuurde zo'n agent
      # helemaal niets, waarna de node na twee minuten offline ging -- niet te
      # onderscheiden van een machine die uit staat, en precies de informatie
      # kwijt die nodig is om het op te lossen.
      %{node: node, agent_token: agent_token} = enroll_node(region)

      gezond = fn ->
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", %{
          "node_id" => node.id,
          "total_vcpu" => 8,
          "avail_vcpu" => 8,
          "total_ram_mb" => 16_384,
          "avail_ram_mb" => 16_384,
          "total_disk_gb" => 500,
          "avail_disk_gb" => 500
        })
      end

      assert json_response(gezond.(), 200)

      kapot =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", %{
          "node_id" => node.id,
          "total_vcpu" => 0,
          "avail_vcpu" => 0,
          "total_ram_mb" => 0,
          "avail_ram_mb" => 0,
          "total_disk_gb" => 0,
          "avail_disk_gb" => 0,
          "capacity_error" => "proxmox: dial tcp 10.0.0.9:8006: connect: no route to host"
        })

      assert json_response(kapot, 200)

      updated = Repo.get!(Node, node.id)
      assert updated.status == :online
      assert updated.capacity_error =~ "no route to host"

      # De laatst bekende totalen blijven staan: die zeggen nog steeds wat deze
      # machine is. De nullen in het bericht zijn geen meting.
      assert updated.total_vcpu == 8
      assert updated.total_ram_mb == 16_384
      assert updated.total_disk_gb == 500

      # Maar er mag niets meer op geplaatst worden zolang hij niet kan kijken.
      assert updated.reported_avail_vcpu == 0
      assert updated.reported_avail_ram_mb == 0
      assert updated.reported_avail_disk_gb == 0
    end

    test "een geslaagde heartbeat wist de eerdere melding", %{conn: conn, region: region} do
      # Anders blijft een opgelost probleem in het paneel staan, en leert een
      # beheerder de melding te negeren.
      %{node: node, agent_token: agent_token} = enroll_node(region)

      stuur = fn extra ->
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(
          ~p"/v1/heartbeat",
          Map.merge(
            %{
              "node_id" => node.id,
              "total_vcpu" => 4,
              "avail_vcpu" => 4,
              "total_ram_mb" => 8192,
              "avail_ram_mb" => 8192,
              "total_disk_gb" => 100,
              "avail_disk_gb" => 100
            },
            extra
          )
        )
      end

      assert json_response(stuur.(%{"capacity_error" => "geen verbinding"}), 200)
      assert Repo.get!(Node, node.id).capacity_error == "geen verbinding"

      assert json_response(stuur.(%{}), 200)
      assert is_nil(Repo.get!(Node, node.id).capacity_error)
      assert Repo.get!(Node, node.id).reported_avail_ram_mb == 8192
    end

    test "het antwoord draagt de instellingen van de node", %{conn: conn, region: region} do
      # Zo landt een wijziging uit het dashboard binnen een heartbeat op de
      # machine, zonder dat iemand daar hoeft in te loggen.
      %{node: node, agent_token: agent_token} = enroll_node(region)

      node
      |> Ecto.Changeset.change(%{
        offer_ram_mb: 3584,
        vmid_min: 2000,
        vmid_max: 2999,
        vcpu_oversubscribe: 4
      })
      |> Repo.update!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", %{"node_id" => node.id, "total_vcpu" => 4})

      assert %{"settings" => instellingen} = json_response(conn, 200)
      assert instellingen["offer_ram_mb"] == 3584
      assert instellingen["vmid_min"] == 2000
      assert instellingen["vcpu_oversubscribe"] == 4

      # Het naampatroon hoort hier niet bij: de naam van een gast wordt door het
      # control plane samengesteld, niet door de agent.
      refute Map.has_key?(instellingen, "guest_name_pattern")
    end

    test "het antwoord draagt het VPS-netwerk van de node", %{conn: conn, region: region} do
      # Eindhoven verhuisde naar een ander net. Dat ging alleen bij de
      # inschrijving mee, dus de draaiende agent weigerde elke terminal naar het
      # nieuwe net tot iemand hem herstartte.
      %{node: node, agent_token: agent_token} = enroll_node(region)

      node
      |> Ecto.Changeset.change(%{
        vps_gateway: "172.16.2.1",
        vps_cidr_prefix: 24,
        vps_range_start: "172.16.2.20",
        vps_range_end: "172.16.2.99"
      })
      |> Repo.update!()

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", %{"node_id" => node.id, "total_vcpu" => 4})

      assert %{"settings" => instellingen} = json_response(conn, 200)
      assert instellingen["vps_gateway"] == "172.16.2.1"
      assert instellingen["vps_cidr_prefix"] == 24
    end

    test "een node zonder instellingen krijgt lege waarden terug", %{conn: conn, region: region} do
      # Null betekent "niet ingesteld"; de agent houdt dan wat er lokaal staat.
      %{node: node, agent_token: agent_token} = enroll_node(region)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/heartbeat", %{"node_id" => node.id, "total_vcpu" => 4})

      assert %{"settings" => instellingen} = json_response(conn, 200)
      assert is_nil(instellingen["offer_ram_mb"])
      assert is_nil(instellingen["vmid_min"])
      # De sleutel moet er zijn en null zijn: de agent leest null als "laat je
      # eigen net staan". Ontbrak hij, dan las een oudere parser het als leeg.
      assert Map.has_key?(instellingen, "vps_gateway")
    end

    test "missing bearer returns 401", %{conn: conn, region: region} do
      %{node: node} = enroll_node(region)

      conn = post(conn, ~p"/v1/heartbeat", %{"node_id" => node.id})

      assert %{"error" => _} = json_response(conn, 401)
    end

    test "bad bearer returns 401", %{conn: conn, region: region} do
      %{node: node} = enroll_node(region)

      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> post(~p"/v1/heartbeat", %{"node_id" => node.id})

      assert %{"error" => _} = json_response(conn, 401)
    end
  end
end
