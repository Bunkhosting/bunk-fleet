defmodule ControlPlaneWeb.CommandControllerTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Enrollment
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  defp create_region(_) do
    region =
      %Region{}
      |> Region.changeset(%{code: "nl-1", name: "Netherlands 1"})
      |> Repo.insert!()

    %{region: region}
  end

  # Enrolls a node and seeds it with capacity (enrollment leaves total/available nil).
  defp enroll_node(region) do
    {:ok, {plaintext, _token}} =
      Enrollment.create_enroll_token(%{
        region_id: region.id,
        ttl_seconds: 3600
      })

    {:ok, %{node: node, agent_token: agent_token}} =
      Enrollment.enroll(plaintext, %{hypervisor: "proxmox", agent_version: "1.2.3"})

    node =
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

    %{node: node, agent_token: agent_token}
  end

  defp create_vps(region) do
    {:ok, %{vps: vps, command: command}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: "web-1",
        vcpu: 4,
        ram_mb: 8192,
        disk_gb: 100,
        owner_email: "owner@example.com",
        template_id: 9000,
        ssh_keys: ["ssh-ed25519 AAAA..."],
        cloud_init: %{"ciuser" => "bunk-console"},
        ip_config: "ip=10.10.0.10/19,gw=10.10.0.1"
      })

    %{vps: vps, command: command}
  end

  setup [:create_region]

  describe "GET /v1/commands" do
    test "returns the node's pending commands and marks them delivered", %{
      conn: conn,
      region: region
    } do
      %{node: node, agent_token: agent_token} = enroll_node(region)
      %{command: command} = create_vps(region)

      # Sanity: the command was placed onto the enrolled node.
      assert command.node_id == node.id

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> get(~p"/v1/commands")

      assert [returned] = json_response(conn, 200)
      assert returned["id"] == command.id
      assert returned["kind"] == "provision"

      assert %{
               "vcpu" => 4,
               "ram_mb" => 8192,
               "disk_gb" => 100,
               "template_id" => 9000,
               "cloud_init" => %{"ciuser" => "bunk-console"},
               # De eigen consolesleutel van deze VPS staat achter die van de
               # klant; zie ProvisioningConsoleKeyTest voor waarom.
               "ssh_keys" => ["ssh-ed25519 AAAA...", _console_key],
               "ip_config" => "ip=10.10.0.10/19,gw=10.10.0.1"
             } = returned["payload"]

      # Unique guest name = display slug + short UUID suffix.
      assert returned["payload"]["name"] =~ ~r/^web-1-[0-9a-f]{8}$/

      assert Repo.get!(Command, command.id).status == :delivered
    end

    test "een commando zegt over welke VPS het gaat", %{conn: conn, region: region} do
      # De agent gebruikt dit om werk te verdelen: commando's voor verschillende
      # VPS'en mogen naast elkaar lopen, voor dezelfde VPS moeten ze op volgorde.
      # Zonder dit veld kan hij dat onderscheid niet maken en valt hij terug op
      # alles strikt na elkaar -- dan wacht de klant die op "stop" drukt op de
      # uitrol van iemand anders.
      %{agent_token: agent_token} = enroll_node(region)
      %{vps: vps} = create_vps(region)

      assert [returned] =
               conn
               |> put_req_header("authorization", "Bearer " <> agent_token)
               |> get(~p"/v1/commands")
               |> json_response(200)

      assert returned["vps_id"] == vps.id
    end

    test "returns [] when there are no pending commands", %{conn: conn, region: region} do
      %{agent_token: agent_token} = enroll_node(region)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> get(~p"/v1/commands")

      assert json_response(conn, 200) == []
    end

    test "missing bearer returns 401", %{conn: conn} do
      conn = get(conn, ~p"/v1/commands")
      assert %{"error" => _} = json_response(conn, 401)
    end
  end

  describe "POST /v1/commands/:id/result" do
    test "done activates the VPS and returns 204", %{conn: conn, region: region} do
      %{agent_token: agent_token} = enroll_node(region)
      %{vps: vps, command: command} = create_vps(region)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/commands/#{command.id}/result", %{
          "status" => "done",
          "vm_id" => "10101",
          "ip" => "10.10.0.10"
        })

      assert response(conn, 204)

      assert Repo.get!(Command, command.id).status == :done
      assert Repo.get!(Vps, vps.id).status == :active
      assert Repo.get_by!(Reservation, vps_id: vps.id).status == :committed
    end

    test "failed marks the VPS failed and releases the reservation", %{
      conn: conn,
      region: region
    } do
      %{agent_token: agent_token} = enroll_node(region)
      %{vps: vps, command: command} = create_vps(region)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> agent_token)
        |> post(~p"/v1/commands/#{command.id}/result", %{
          "status" => "failed",
          "error" => "boom"
        })

      assert response(conn, 204)

      assert Repo.get!(Command, command.id).status == :failed
      assert Repo.get!(Vps, vps.id).status == :failed
      assert Repo.get_by!(Reservation, vps_id: vps.id).status == :released
    end

    test "een te lange foutmelding wordt ingekort bewaard", %{conn: conn, region: region} do
      # De node hoeft niet van ons te zijn: zonder grens zette hij per opdracht
      # twee megabyte in de gedeelde database.
      %{agent_token: agent_token} = enroll_node(region)
      %{command: command} = create_vps(region)

      conn
      |> put_req_header("authorization", "Bearer " <> agent_token)
      |> post(~p"/v1/commands/#{command.id}/result", %{
        "status" => "failed",
        "error" => String.duplicate("x", 100_000)
      })
      |> response(204)

      assert String.length(Repo.get!(Command, command.id).result["error"]) == 500
    end

    test "a command belonging to another node returns 404", %{conn: conn, region: region} do
      # The command is placed onto the first enrolled node...
      %{node: _first} = enroll_node(region)
      %{command: command} = create_vps(region)
      # ...but a different node tries to resolve it.
      %{agent_token: other_token} = enroll_node(region)

      conn =
        conn
        |> put_req_header("authorization", "Bearer " <> other_token)
        |> post(~p"/v1/commands/#{command.id}/result", %{"status" => "done"})

      assert %{"error" => _} = json_response(conn, 404)
      # Untouched.
      assert Repo.get!(Command, command.id).status == :pending
    end
  end
end
