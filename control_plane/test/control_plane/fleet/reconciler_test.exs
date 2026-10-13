defmodule ControlPlane.Fleet.ReconcilerTest do
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Billing.UsageRecord
  alias ControlPlane.Fleet.Liveness
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Reconciler
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias Ecto.Adapters.SQL.Sandbox

  # --- inline insert helpers -------------------------------------------------

  defp insert_region(attrs \\ %{}) do
    code = "r-#{System.unique_integer([:positive])}"

    %Region{}
    |> Region.changeset(Map.merge(%{code: code, name: "Region #{code}"}, attrs))
    |> Repo.insert!()
  end

  defp insert_node(region, attrs) do
    base = %{
      name: "node-#{System.unique_integer([:positive])}",
      region_id: region.id,
      status: :online,
      last_heartbeat_at: now()
    }

    attrs = Map.merge(base, attrs)

    # Node.changeset doesn't cast :status/:last_heartbeat_at on a fresh struct in
    # a meaningful way for our needs, so force them explicitly.
    %Node{}
    |> Node.changeset(attrs)
    |> Ecto.Changeset.put_change(:status, attrs.status)
    |> Ecto.Changeset.put_change(:last_heartbeat_at, attrs.last_heartbeat_at)
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp stale_at, do: DateTime.add(now(), -(Liveness.heartbeat_ttl_seconds() + 60), :second)

  defp reload(node), do: Repo.get!(Node, node.id)

  # --- Liveness.mark_stale_nodes_offline/0 --------------------------------------

  describe "mark_stale_nodes_offline/0" do
    test "flips an :online node with a stale heartbeat to :offline" do
      region = insert_region()
      stale = insert_node(region, %{status: :online, last_heartbeat_at: stale_at()})

      assert {1, _} = Liveness.mark_stale_nodes_offline()
      assert reload(stale).status == :offline
    end

    test "leaves an :online node with a recent heartbeat as :online" do
      region = insert_region()
      fresh = insert_node(region, %{status: :online, last_heartbeat_at: now()})

      assert {0, _} = Liveness.mark_stale_nodes_offline()
      assert reload(fresh).status == :online
    end

    test "flips an :online node with a nil heartbeat to :offline" do
      region = insert_region()
      never = insert_node(region, %{status: :online, last_heartbeat_at: nil})

      assert {1, _} = Liveness.mark_stale_nodes_offline()
      assert reload(never).status == :offline
    end

    test "leaves a :draining node with a stale heartbeat as :draining" do
      region = insert_region()
      draining = insert_node(region, %{status: :draining, last_heartbeat_at: stale_at()})

      assert {0, _} = Liveness.mark_stale_nodes_offline()
      assert reload(draining).status == :draining
    end

    test "leaves :pending and already-:offline nodes untouched" do
      region = insert_region()
      pending = insert_node(region, %{status: :pending, last_heartbeat_at: stale_at()})
      offline = insert_node(region, %{status: :offline, last_heartbeat_at: stale_at()})

      assert {0, _} = Liveness.mark_stale_nodes_offline()
      assert reload(pending).status == :pending
      assert reload(offline).status == :offline
    end

    test "only flips the stale nodes when a mix is present" do
      region = insert_region()
      stale = insert_node(region, %{status: :online, last_heartbeat_at: stale_at()})
      fresh = insert_node(region, %{status: :online, last_heartbeat_at: now()})

      assert {1, _} = Liveness.mark_stale_nodes_offline()
      assert reload(stale).status == :offline
      assert reload(fresh).status == :online
    end
  end

  # --- GenServer smoke test --------------------------------------------------

  # Not async: a shared sandbox connection is required so the Reconciler process
  # (a different pid) can see the data we insert and write back to it.
  describe "Reconciler GenServer" do
    # The Reconciler runs in its own pid; Ecto.Adapters.SQL.Sandbox.allow/3 (below)
    # shares this test's sandbox connection with it so it sees our inserts.
    test "marks a stale node offline on its tick" do
      region = insert_region()
      stale = insert_node(region, %{status: :online, last_heartbeat_at: stale_at()})

      {:ok, pid} = Reconciler.start_link(interval_ms: 5)
      Sandbox.allow(Repo, self(), pid)

      assert eventually(fn -> reload(stale).status == :offline end)
    end

    test "one tick converges every condition it finds, not just the first" do
      # The sub-steps are independent and run in sequence. If an early one were to
      # short-circuit the tick, the fleet would converge one problem per interval
      # and a busy fleet would never catch up.
      region = insert_region()
      stale = insert_node(region, %{status: :online, last_heartbeat_at: stale_at()})
      queued = insert_stuck_queued_vps(region)

      {:ok, pid} = Reconciler.start_link(interval_ms: 5)
      Sandbox.allow(Repo, self(), pid)

      assert eventually(fn ->
               reload(stale).status == :offline and Repo.get!(Vps, queued.id).status == :failed
             end)
    end

    test "a database that refuses the reconciler does not kill it" do
      # No Sandbox.allow: every Repo call inside the tick raises. Each sub-step
      # rescues its own failure, so the process must keep ticking rather than
      # crash — a reconciler that dies on a bad tick stops metering, stops
      # reclaiming capacity and stops retrying teardowns, silently.
      Process.flag(:trap_exit, true)
      {:ok, pid} = Reconciler.start_link(interval_ms: 5)

      # Several intervals' worth: long enough for a tick to have raised and for
      # the next one to have been scheduled.
      Process.sleep(60)

      assert Process.alive?(pid)
      refute_received {:EXIT, ^pid, _}
    end

    test "metering is gated by its own interval, not by the tick rate" do
      # Ticks are seconds apart and metering is hourly. Metering on every tick
      # would bill each VPS once per tick — the interval gate is the only thing
      # standing between a customer and a bill multiplied by 3600.
      {:ok, pid} = Reconciler.start_link(interval_ms: 5, meter_interval_ms: 3_600_000)
      Sandbox.allow(Repo, self(), pid)

      before = Repo.aggregate(UsageRecord, :count, :vps_id)
      Process.sleep(60)

      # The first tick meters (catching up any elapsed runtime); no later tick in
      # this window may add another record.
      assert Repo.aggregate(UsageRecord, :count, :vps_id) == before
    end
  end

  # A VPS that was persisted but never dispatched: the control plane stopped
  # between the two. Aged past the grace period so the sweep picks it up.
  defp insert_stuck_queued_vps(region) do
    old = DateTime.add(now(), -7200, :second)

    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :queued
    })
    |> Ecto.Changeset.put_change(:inserted_at, old)
    |> Ecto.Changeset.put_change(:updated_at, old)
    |> Repo.insert!()
  end

  # Polls `fun` until it returns a truthy value or the timeout elapses.
  defp eventually(fun, timeout_ms \\ 1_000, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, interval_ms)
  end

  defp do_eventually(fun, deadline, interval_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(interval_ms)
        do_eventually(fun, deadline, interval_ms)
      end
    end
  end
end
