defmodule ControlPlane.Subscriptions do
  @moduledoc "Customer subscriptions — one per VPS, charged at the package price."
  import Ecto.Query
  require Logger

  alias ControlPlane.Accounts
  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Notifier
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription

  # A VPS in one of these states is gone (or never came up); its subscription must
  # never be charged. `:failed` is included so a provision that never produced a VM
  # is cancelled by the settle loop instead of billed monthly.
  @dead_vps_statuses [:deleting, :deleted, :failed]

  @doc "Creates an active subscription for a VPS from its package (idempotent on vps_id)."
  def create_for_vps(vps, owner_id, package_id) when not is_nil(package_id) do
    case Fleet.get_package(package_id) do
      nil ->
        {:error, :no_package}

      pkg ->
        today = Date.utc_today()

        %Subscription{}
        |> Subscription.changeset(%{
          vps_id: vps.id,
          owner_id: owner_id,
          package_id: pkg.id,
          price_monthly: pkg.price_monthly,
          status: :active,
          billing_cycle: :monthly,
          started_at: Clock.now(),
          next_billing_date: next_month(today)
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: :vps_id)
    end
  end

  def create_for_vps(_vps, _owner_id, _package_id), do: {:ok, nil}

  @doc "The earliest upcoming billing date across active subscriptions."
  def next_billing_date(owner_id) do
    Repo.one(
      from s in Subscription,
        where:
          s.owner_id == ^owner_id and s.status == :active and not is_nil(s.next_billing_date),
        select: min(s.next_billing_date)
    )
  end

  @doc """
  Cancels the subscription for a (soft-)deleted VPS so the recurring runner never
  charges for a server that no longer exists. Idempotent.
  """
  def cancel_for_vps(vps_id) do
    now = Clock.now()

    {n, _} =
      Repo.update_all(
        from(s in Subscription, where: s.vps_id == ^vps_id and s.status != :cancelled),
        set: [status: :cancelled, cancelled_at: now, updated_at: now]
      )

    {:ok, n}
  end

  @doc """
  Of de VPS stilstaat omdat de eigenaar niet kon betalen.

  Schorsen is een stopcommando, en een stopcommando is iets wat de klant met één
  klik ongedaan maakt. Zonder deze vraag draaide een geschorste VPS dus gewoon
  weer, onbetaald, tot de dagelijkse nieuwe poging hem opnieuw stopte.
  """
  @spec geschorst?(binary()) :: boolean()
  def geschorst?(vps_id) do
    Repo.exists?(from s in Subscription, where: s.vps_id == ^vps_id and s.status == :past_due)
  end

  @doc """
  Settles every subscription that has come due (`next_billing_date <= today`):

    * charges the owner's wallet the monthly price and advances the billing date
      one period FROM THE ANCHOR (the original due date), so the customer's
      billing day never drifts;
    * on insufficient credit, suspends (stops) the VPS and marks the subscription
      `:past_due` with `retry_at = tomorrow` — the anchor stays untouched;
    * a later successful charge of a `:past_due` subscription resumes the VPS.

  Subscriptions whose VPS is (being) deleted are cancelled instead of charged.
  Returns a summary map. `today` is injectable for testing.
  """
  def settle_due(today \\ Date.utc_today()) do
    due =
      Repo.all(
        from s in Subscription,
          join: v in Vps,
          on: v.id == s.vps_id,
          where:
            s.status in [:active, :past_due] and
              not is_nil(s.next_billing_date) and
              s.next_billing_date <= ^today and
              (is_nil(s.retry_at) or s.retry_at <= ^today),
          order_by: [asc: s.next_billing_date],
          # Cap work per tick; each settled subscription advances its own date, so
          # a large backlog simply drains over the next few 30s ticks.
          limit: 200,
          preload: [vps: v]
      )

    Enum.reduce(due, %{charged: 0, suspended: 0, resumed: 0, cancelled: 0, errors: 0}, fn sub,
                                                                                          acc ->
      # Isolate each subscription: one that raises (e.g. a ledger constraint) must
      # not abort the whole tick and starve the subscriptions behind it (the scan is
      # ordered by date, so a permanently-failing oldest row would recur first).
      try do
        settle_one(sub, today, acc)
      rescue
        e ->
          Logger.error("subscription settle crashed for #{sub.id}: #{Exception.message(e)}")
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  defp settle_one(%Subscription{vps: %Vps{status: st}} = sub, _today, acc)
       when st in @dead_vps_statuses do
    {:ok, _} = cancel_for_vps(sub.vps_id)
    %{acc | cancelled: acc.cancelled + 1}
  end

  defp settle_one(%Subscription{} = sub, today, acc) do
    was_past_due = sub.status == :past_due

    case charge_and_advance(sub, today) do
      {:ok, _} ->
        resumed = if was_past_due, do: maybe_resume(sub), else: 0
        %{acc | charged: acc.charged + 1, resumed: acc.resumed + resumed}

      {:error, :insufficient_credits} ->
        retry_date = Date.add(today, 1)
        suspended = maybe_suspend(sub)
        mark_past_due(sub, retry_date)
        unless was_past_due, do: notify_past_due(sub, retry_date)
        %{acc | suspended: acc.suspended + suspended}

      # Another settler already claimed this period (multi-instance race) — no-op.
      {:error, :already_settled} ->
        acc

      {:error, reason} ->
        Logger.error("subscription settle failed for #{sub.id}: #{inspect(reason)}")
        %{acc | errors: acc.errors + 1}
    end
  end

  # Charge the wallet and advance the billing date in ONE transaction, under the
  # same per-user advisory lock Credits.charge/4 uses — so a charge can never be
  # applied without the date also moving (no double-billing on the next tick).
  defp charge_and_advance(%Subscription{} = sub, today) do
    cents = to_cents(sub.price_monthly)

    Repo.transaction(fn ->
      # Same class and key as Credits.charge/4: these are one critical section.
      :ok = ControlPlane.Locks.take(Repo, :wallet, sub.owner_id)

      # Atomically CLAIM this billing period: advance the date only while the row is
      # still due AND still carries the anchor we read (so a concurrent settler that
      # already advanced it can't be double-charged, and the anchor arithmetic below
      # is guaranteed to start from the row's real value). A rollback below undoes
      # this advance, so an unaffordable charge leaves the date untouched.
      {claimed, _} =
        Repo.update_all(
          from(s in Subscription,
            where:
              s.id == ^sub.id and s.status in [:active, :past_due] and
                s.next_billing_date == ^sub.next_billing_date and
                s.next_billing_date <= ^today
          ),
          set: [
            status: :active,
            next_billing_date: advance_from_anchor(sub.next_billing_date, today),
            retry_at: nil,
            updated_at: ts()
          ]
        )

      cond do
        claimed == 0 ->
          Repo.rollback(:already_settled)

        Credits.balance_cents(sub.owner_id) >= cents ->
          {:ok, _} =
            Credits.add_entry(
              sub.owner_id,
              -cents,
              "vps_charge",
              "Maandelijkse verlenging: #{sub.vps.name}",
              # Zonder vps_id is dit voor `Credits.refund_orphan_charges/1` een
              # afschrijving voor een VPS die nooit is aangemaakt, en die betaalt
              # hem tien minuten later terug. Elke verlenging, elke maand.
              sub.vps_id
            )

          claimed

        true ->
          Repo.rollback(:insufficient_credits)
      end
    end)
  end

  # Throttle the retry via retry_at and leave next_billing_date (the anchor)
  # untouched. Overwriting the anchor with the retry date — as this used to do —
  # made every insufficient-credit blip drift the customer's billing day forward,
  # accumulating free days over time.
  defp mark_past_due(%Subscription{} = sub, retry_date) do
    Repo.update_all(
      from(s in Subscription, where: s.id == ^sub.id),
      set: [status: :past_due, retry_at: retry_date, updated_at: ts()]
    )
  end

  # Stop a still-running VPS when its owner can't pay (dispatch happens outside the
  # money transaction). Returns 1 if a stop was dispatched, else 0.
  defp maybe_suspend(%Subscription{vps: %Vps{status: st}} = sub) when st in [:active, :paused] do
    case Provisioning.stop_vps(sub.vps_id) do
      {:ok, _} -> 1
      _ -> 0
    end
  end

  defp maybe_suspend(_sub), do: 0

  # Only sent on the FIRST insufficient-credit tick for a subscription (guarded by
  # `was_past_due` at the call site), not on every retry — otherwise a customer
  # who stays broke for a week gets the same warning once a day. Never raises:
  # Notifier already swallows and logs mail-delivery failures, so a dead SMTP
  # relay can't turn a normal suspend into a settle_due error.
  defp notify_past_due(%Subscription{} = sub, retry_date) do
    case Accounts.get_user(sub.owner_id) do
      nil -> :ok
      user -> Notifier.deliver_low_balance_warning(user, sub.vps.name, retry_date)
    end
  end

  # Resume a VPS we previously suspended, now that the owner has paid again.
  defp maybe_resume(%Subscription{vps: %Vps{status: :stopped}} = sub) do
    case Provisioning.start_vps(sub.vps_id) do
      {:ok, _} -> 1
      _ -> 0
    end
  end

  defp maybe_resume(_sub), do: 0

  defp to_cents(%Decimal{} = price), do: ControlPlane.Money.to_cents(price)

  defp ts, do: Clock.now()

  # One period on from the ANCHOR (the original due date), not from the settle day,
  # so a short past_due retry never shifts the billing day. Guard: if the sub was
  # delinquent for so long that one period from the anchor is still not in the
  # future (the VPS spent over a month suspended), re-anchor from today — charging
  # once for the month ahead — rather than immediately coming due again and
  # retroactively billing time the customer never had service.
  defp advance_from_anchor(anchor, today) do
    candidate = next_month(anchor)
    if Date.compare(candidate, today) == :gt, do: candidate, else: next_month(today)
  end

  defp next_month(date) do
    case Date.new(date.year, date.month, 1) do
      {:ok, first} ->
        Date.add(first, 31) |> then(&%{&1 | day: min(date.day, Date.days_in_month(&1))})

      _ ->
        Date.add(date, 30)
    end
  end
end
