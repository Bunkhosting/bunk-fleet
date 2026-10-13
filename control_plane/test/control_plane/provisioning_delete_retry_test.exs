defmodule ControlPlane.ProvisioningDeleteRetryTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning.Teardown

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp node_in(region) do
    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp deleting_vps(region, node) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :deleting,
      provider_vm_id: "#{100 + System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp delete_command(vps, status, age_seconds) do
    at = DateTime.utc_now() |> DateTime.add(-age_seconds, :second) |> DateTime.truncate(:second)

    %Command{}
    |> Command.changeset(%{
      node_id: vps.node_id,
      vps_id: vps.id,
      kind: :delete,
      status: status,
      payload: %{"vm_id" => vps.provider_vm_id}
    })
    |> Ecto.Changeset.change(%{inserted_at: at, updated_at: at})
    |> Repo.insert!()
  end

  defp delete_commands(vps_id) do
    Repo.all(from c in Command, where: c.vps_id == ^vps_id and c.kind == :delete)
  end

  test "a teardown that failed long enough ago is retried" do
    r = region()
    vps = deleting_vps(r, node_in(r))
    delete_command(vps, :failed, 3600)

    assert Teardown.retry_stuck_deletes(300) == 1
    assert Enum.any?(delete_commands(vps.id), &(&1.status == :pending))
  end

  test "one that failed moments ago is left to settle" do
    r = region()
    vps = deleting_vps(r, node_in(r))
    delete_command(vps, :failed, 10)

    assert Teardown.retry_stuck_deletes(300) == 0
  end

  test "a teardown still in flight is not duplicated" do
    # Two delete commands for one VM is how you get an agent racing itself.
    r = region()
    vps = deleting_vps(r, node_in(r))
    delete_command(vps, :failed, 3600)
    delete_command(vps, :delivered, 5)

    assert Teardown.retry_stuck_deletes(300) == 0
  end

  test "the wait doubles with each failure" do
    # A genuinely broken teardown must stop producing a command every tick while
    # still being retried hours later, when a node comes back from maintenance.
    r = region()
    vps = deleting_vps(r, node_in(r))

    # Three failures, the newest 20 minutes old: the fourth attempt is due after
    # 5 * 2^2 = 20 minutes, so it is due — just.
    delete_command(vps, :failed, 4000)
    delete_command(vps, :failed, 3000)
    delete_command(vps, :failed, 1200)

    assert Teardown.retry_stuck_deletes(300) == 1
  end

  test "with more failures the same age is no longer due" do
    r = region()
    vps = deleting_vps(r, node_in(r))

    # Five failures: the next attempt waits 5 * 2^4 = 80 minutes.
    for age <- [9000, 8000, 7000, 6000, 1200], do: delete_command(vps, :failed, age)

    assert Teardown.retry_stuck_deletes(300) == 0
  end

  test "the backoff has a ceiling, so a long-dead node is still retried" do
    r = region()
    vps = deleting_vps(r, node_in(r))

    # Ten failures would be 5 * 2^9 = ~42 hours without a ceiling.
    for i <- 1..10, do: delete_command(vps, :failed, 100_000 + i)
    delete_command(vps, :failed, 8 * 3600)

    assert Teardown.retry_stuck_deletes(300, 6 * 3600) == 1
  end

  test "a VPS that is not being deleted is never touched" do
    r = region()
    node = node_in(r)
    vps = deleting_vps(r, node)
    {:ok, _} = vps |> Vps.changeset(%{status: :active}) |> Repo.update()
    delete_command(vps, :failed, 3600)

    assert Teardown.retry_stuck_deletes(300) == 0
  end

  test "a VPS with no failed teardown behind it is not retried" do
    r = region()
    _vps = deleting_vps(r, node_in(r))

    assert Teardown.retry_stuck_deletes(300) == 0
  end
end
