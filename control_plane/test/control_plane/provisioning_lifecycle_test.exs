defmodule ControlPlane.ProvisioningLifecycleTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Provisioning.Power
  alias ControlPlane.Provisioning.Teardown

  defp insert_region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Region #{code}"}) |> Repo.insert!()
  end

  defp insert_node(region) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
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

  defp insert_vps(region, node, status, opts) do
    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      vcpu: 2,
      ram_mb: 4096,
      disk_gb: 50,
      provider_vm_id: Keyword.get(opts, :provider_vm_id, "105")
    })
    |> Ecto.Changeset.put_change(:status, status)
    |> Repo.insert!()
  end

  defp setup_vps(status, opts \\ []) do
    region = insert_region()
    node = insert_node(region)
    insert_vps(region, node, status, opts)
  end

  describe "power dispatch guards" do
    test "start_vps from :stopped enqueues a :start command with the vm id" do
      vps = setup_vps(:stopped)
      assert {:ok, %{command: cmd}} = Power.start_vps(vps.id)
      assert cmd.kind == :start
      assert cmd.payload == %{"vm_id" => "105"}
    end

    test "stop_vps allowed from :active and :paused" do
      for status <- [:active, :paused] do
        assert {:ok, %{command: cmd}} = Power.stop_vps(setup_vps(status).id)
        assert cmd.kind == :stop
      end
    end

    test "pause_vps only from :active" do
      assert {:ok, %{command: cmd}} = Power.pause_vps(setup_vps(:active).id)
      assert cmd.kind == :pause

      assert {:error, {:invalid_status, :stopped}} =
               Power.pause_vps(setup_vps(:stopped).id)
    end

    test "resume_vps only from :paused" do
      assert {:ok, %{command: cmd}} = Power.resume_vps(setup_vps(:paused).id)
      assert cmd.kind == :resume
      assert {:error, {:invalid_status, :active}} = Power.resume_vps(setup_vps(:active).id)
    end

    test "start_vps invalid from :active" do
      assert {:error, {:invalid_status, :active}} = Power.start_vps(setup_vps(:active).id)
    end

    test "not_provisioned when provider_vm_id is missing" do
      assert {:error, :not_provisioned} =
               Power.start_vps(setup_vps(:stopped, provider_vm_id: nil).id)
    end

    test "not_found for unknown vps" do
      assert {:error, :not_found} = Power.start_vps(Ecto.UUID.generate())
    end
  end

  describe "apply_result power transitions" do
    test "start done -> :active" do
      vps = setup_vps(:stopped)
      {:ok, %{command: cmd}} = Power.start_vps(vps.id)
      assert {:ok, _} = Provisioning.apply_result(cmd, %{"status" => "done"})
      assert Repo.get!(Vps, vps.id).status == :active
    end

    test "stop done -> :stopped" do
      vps = setup_vps(:active)
      {:ok, %{command: cmd}} = Power.stop_vps(vps.id)
      assert {:ok, _} = Provisioning.apply_result(cmd, %{"status" => "done"})
      assert Repo.get!(Vps, vps.id).status == :stopped
    end

    test "pause done -> :paused then resume done -> :active" do
      vps = setup_vps(:active)
      {:ok, %{command: pcmd}} = Power.pause_vps(vps.id)
      {:ok, _} = Provisioning.apply_result(pcmd, %{"status" => "done"})
      assert Repo.get!(Vps, vps.id).status == :paused

      {:ok, %{command: rcmd}} = Power.resume_vps(vps.id)
      {:ok, _} = Provisioning.apply_result(rcmd, %{"status" => "done"})
      assert Repo.get!(Vps, vps.id).status == :active
    end

    test "failed power command leaves status unchanged" do
      vps = setup_vps(:active)
      {:ok, %{command: cmd}} = Power.stop_vps(vps.id)
      assert {:ok, _} = Provisioning.apply_result(cmd, %{"status" => "failed", "error" => "boom"})
      assert Repo.get!(Vps, vps.id).status == :active
    end

    test "power result is idempotent on redelivery" do
      vps = setup_vps(:active)
      {:ok, %{command: cmd}} = Power.stop_vps(vps.id)
      assert {:ok, _} = Provisioning.apply_result(cmd, %{"status" => "done"})
      assert {:ok, _} = Provisioning.apply_result(cmd, %{"status" => "done"})
      assert Repo.get!(Vps, vps.id).status == :stopped
    end
  end

  describe "delete retry" do
    test "re-dispatches a delete after the previous one terminally failed" do
      vps = setup_vps(:active)
      {:ok, %{command: cmd}} = Teardown.delete_vps(vps.id)
      # Agent reports the destroy failed (e.g. transient Proxmox error); the
      # command becomes terminal but the VPS stays :deleting.
      {:ok, _} =
        Provisioning.apply_result(cmd, %{"status" => "failed", "error" => "VM is running"})

      assert Repo.get!(Vps, vps.id).status == :deleting

      # A fresh delete is allowed (no in-flight command) and enqueues a new one.
      assert {:ok, %{command: cmd2}} = Teardown.delete_vps(vps.id)
      assert cmd2.kind == :delete
      assert cmd2.id != cmd.id
    end

    test "blocks a second delete while one is still in flight" do
      vps = setup_vps(:active)
      {:ok, _} = Teardown.delete_vps(vps.id)
      assert {:error, :already_deleting} = Teardown.delete_vps(vps.id)
    end
  end
end
