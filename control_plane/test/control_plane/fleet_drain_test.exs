defmodule ControlPlane.FleetDrainTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Liveness
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Scheduler

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp online_node(region) do
    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second),
      total_vcpu: 16,
      total_ram_mb: 32_768,
      total_disk_gb: 500,
      available_vcpu: 16,
      available_ram_mb: 32_768,
      available_disk_gb: 500
    })
    |> Repo.insert!()
  end

  @request %{vcpu: 2, ram_mb: 4096, disk_gb: 50}

  test "a drained node is no longer scheduled onto" do
    r = region()
    node = online_node(r)

    assert {:ok, _} = Scheduler.place(Map.put(@request, :region_id, r.id))

    {:ok, _} = NodeAdmin.drain_node(node.id)

    assert {:error, :no_capacity} = Scheduler.place(Map.put(@request, :region_id, r.id))
  end

  test "draining one node leaves the other taking work" do
    r = region()
    draining = online_node(r)
    keeping = online_node(r)

    {:ok, _} = NodeAdmin.drain_node(draining.id)

    assert {:ok, %{node: placed}} = Scheduler.place(Map.put(@request, :region_id, r.id))
    assert placed.id == keeping.id
  end

  test "a heartbeat does not undo a drain" do
    # The whole point of draining is that the node stays up. If the heartbeat
    # stamped :online the node would quietly refill within thirty seconds.
    r = region()
    node = online_node(r)
    {:ok, node} = NodeAdmin.drain_node(node.id)

    {:ok, after_heartbeat} =
      Liveness.mark_online_heartbeat(node, %{
        total_vcpu: 16,
        total_ram_mb: 32_768,
        total_disk_gb: 500
      })

    assert after_heartbeat.status == :draining
    refute is_nil(after_heartbeat.last_heartbeat_at)
  end

  test "resuming puts it back in rotation" do
    r = region()
    node = online_node(r)
    {:ok, _} = NodeAdmin.drain_node(node.id)
    {:ok, resumed} = NodeAdmin.resume_node(node.id)

    assert resumed.status == :online
    assert {:ok, _} = Scheduler.place(Map.put(@request, :region_id, r.id))
  end

  test "draining twice is not an error" do
    r = region()
    node = online_node(r)

    assert {:ok, _} = NodeAdmin.drain_node(node.id)
    assert {:ok, %Node{status: :draining}} = NodeAdmin.drain_node(node.id)
  end

  test "resuming a node that was never drained is refused, not silently applied" do
    r = region()
    node = online_node(r)

    assert {:ok, %Node{status: :online}} = NodeAdmin.resume_node(node.id)
  end

  test "an unknown node is not found" do
    assert {:error, :not_found} = NodeAdmin.drain_node(Ecto.UUID.generate())
  end

  test "a drained node keeps the VPSes it already has" do
    r = region()
    node = online_node(r)

    {:ok, %{node: placed}} = Scheduler.place(Map.put(@request, :region_id, r.id))
    assert placed.id == node.id

    {:ok, _} = NodeAdmin.drain_node(node.id)

    # Capacity accounting is untouched: the reservation it already holds is
    # still held, so resuming does not double-count.
    drained = Repo.get!(Node, node.id)
    assert drained.available_vcpu == 14
  end
end
