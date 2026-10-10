defmodule ControlPlane.SubscriptionsSettleTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Credits
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Subscriptions
  alias ControlPlane.Subscriptions.Subscription

  defp insert_user do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "sub#{n}@example.com",
        password: "super-secret-pw-123",
        name: "Sub"
      })

    # Drain the signup bonus so every test starts from a 0 balance and the
    # charged/uncharged expectations are deterministic.
    {:ok, _} =
      Credits.add_entry(
        user.id,
        -Credits.balance_cents(user.id),
        "admin_adjustment",
        "test reset"
      )

    user
  end

  defp insert_vps(status \\ :active) do
    code = "r-#{System.unique_integer([:positive])}"

    region =
      %Region{} |> Region.changeset(%{code: code, name: "Region #{code}"}) |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: region.id
      })
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

    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      vcpu: 2,
      ram_mb: 4096,
      disk_gb: 50,
      provider_vm_id: "105"
    })
    |> Ecto.Changeset.put_change(:status, status)
    |> Repo.insert!()
  end

  defp insert_subscription(user, vps, due_date, attrs \\ %{}) do
    %Subscription{}
    |> Subscription.changeset(%{
      vps_id: vps.id,
      owner_id: user.id,
      package_id: 1,
      price_monthly: Decimal.new("10.00"),
      status: :active,
      started_at: DateTime.truncate(DateTime.utc_now(), :second),
      next_billing_date: due_date
    })
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  test "a successful charge advances one period from the anchor, not the settle day" do
    user = insert_user()
    {:ok, _} = Credits.add_entry(user.id, 5_000, "topup", "test")
    sub = insert_subscription(user, insert_vps(), ~D[2026-07-05])

    # The runner is 2 days late; the customer must not gain 2 free days.
    assert %{charged: 1} = Subscriptions.settle_due(~D[2026-07-07])

    sub = Repo.get!(Subscription, sub.id)
    assert sub.next_billing_date == ~D[2026-08-05]
    assert sub.status == :active
    assert sub.retry_at == nil
  end

  test "een verlenging is geen verweesde afschrijving en wordt niet terugbetaald" do
    # De weessweep betaalt elke vps_charge zonder vps_id terug. De verlenging
    # schreef er nooit een, dus elke maand ging het geld tien minuten later terug.
    user = insert_user()
    {:ok, _} = Credits.add_entry(user.id, 5_000, "topup", "test")
    vps = insert_vps()
    insert_subscription(user, vps, ~D[2026-07-05])

    assert %{charged: 1} = Subscriptions.settle_due(~D[2026-07-05])
    # Eerst vaststellen dat er werkelijk is afgeschreven: zonder dat zou de rest
    # van deze test om de verkeerde reden slagen.
    assert Credits.balance_cents(user.id) == 4_000

    assert Credits.refund_orphan_charges(0) == 0
    assert Credits.balance_cents(user.id) == 4_000

    assert [regel] =
             Repo.all(
               from e in ControlPlane.Credits.LedgerEntry,
                 where: e.user_id == ^user.id and e.kind == "vps_charge"
             )

    assert regel.vps_id == vps.id
  end

  test "insufficient credit marks past_due but keeps the billing anchor" do
    user = insert_user()
    sub = insert_subscription(user, insert_vps(), ~D[2026-07-05])

    assert %{charged: 0} = Subscriptions.settle_due(~D[2026-07-05])

    sub = Repo.get!(Subscription, sub.id)
    assert sub.status == :past_due
    # The anchor survives; only the retry throttle moves.
    assert sub.next_billing_date == ~D[2026-07-05]
    assert sub.retry_at == ~D[2026-07-06]
  end

  test "a past_due retry that succeeds advances from the ORIGINAL anchor (no free days)" do
    user = insert_user()
    sub = insert_subscription(user, insert_vps(:stopped), ~D[2026-07-05])

    # Day 1: no credit → past_due, retry tomorrow.
    assert %{charged: 0} = Subscriptions.settle_due(~D[2026-07-05])
    # Day 4: the customer topped up; the retry succeeds.
    {:ok, _} = Credits.add_entry(user.id, 5_000, "topup", "test")
    assert %{charged: 1} = Subscriptions.settle_due(~D[2026-07-08])

    sub = Repo.get!(Subscription, sub.id)
    # Anchored on the 5th — NOT drifted to Aug 8 (which would gift 3 free days
    # on every payment blip).
    assert sub.next_billing_date == ~D[2026-08-05]
    assert sub.status == :active
    assert sub.retry_at == nil
  end

  test "retry_at throttles retries until the retry day arrives" do
    user = insert_user()
    sub = insert_subscription(user, insert_vps(:stopped), ~D[2026-07-05])

    assert %{charged: 0, errors: 0} = Subscriptions.settle_due(~D[2026-07-05])
    {:ok, _} = Credits.add_entry(user.id, 5_000, "topup", "test")

    # Same-day re-run: throttled by retry_at (tomorrow), so nothing is charged.
    assert %{charged: 0} = Subscriptions.settle_due(~D[2026-07-05])
    assert Repo.get!(Subscription, sub.id).status == :past_due

    # Next day the retry fires.
    assert %{charged: 1} = Subscriptions.settle_due(~D[2026-07-06])
    assert Repo.get!(Subscription, sub.id).next_billing_date == ~D[2026-08-05]
  end

  test "a long-delinquent subscription re-anchors from today instead of billing suspended time" do
    user = insert_user()
    sub = insert_subscription(user, insert_vps(:stopped), ~D[2026-05-01])

    # Suspended for over two months; the customer finally pays on Jul 7.
    {:ok, _} = Credits.add_entry(user.id, 5_000, "topup", "test")
    assert %{charged: 1} = Subscriptions.settle_due(~D[2026-07-07])

    sub = Repo.get!(Subscription, sub.id)
    # One charge, next period from today — NOT Jun 1 (which would immediately come
    # due again and retroactively bill months of suspended service).
    assert sub.next_billing_date == ~D[2026-08-07]
    # Exactly one month was charged.
    assert Credits.balance_cents(user.id) == 4_000
  end

  test "the same period can never be settled twice (idempotent claim)" do
    user = insert_user()
    {:ok, _} = Credits.add_entry(user.id, 5_000, "topup", "test")
    sub = insert_subscription(user, insert_vps(), ~D[2026-07-05])

    assert %{charged: 1} = Subscriptions.settle_due(~D[2026-07-05])
    # A second run the same day: the row's date has moved on, nothing is due.
    assert %{charged: 0} = Subscriptions.settle_due(~D[2026-07-05])
    assert Credits.balance_cents(user.id) == 4_000
    assert Repo.get!(Subscription, sub.id).next_billing_date == ~D[2026-08-05]
  end
end
