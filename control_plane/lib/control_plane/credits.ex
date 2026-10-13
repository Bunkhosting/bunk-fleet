defmodule ControlPlane.Credits do
  @moduledoc """
  Prepaid customer credit wallet — the internal stand-in for a real payment
  provider (Mollie comes later). Each user's balance is the sum of a signed
  `ledger_entries` log (integer cents; positive = credit, negative = charge).

  New users receive a signup bonus; creating a VPS charges a flat monthly price
  by size. This is the *customer-facing* side only — internal cost accounting uses the
  separate per-resource-hour metering in `ControlPlane.Billing`. Opwaarderingen
  staan in `ControlPlane.Credits.Topups`.
  """
  import Ecto.Query

  require Logger
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Repo

  @signup_bonus_cents 1000
  @size_prices_cents %{"small" => 300, "medium" => 600, "large" => 1200}

  def signup_bonus_cents, do: @signup_bonus_cents
  def size_prices_cents, do: @size_prices_cents

  @doc "Current balance in cents (0 when the user has no entries)."
  @spec balance_cents(binary()) :: integer()
  def balance_cents(user_id) do
    Repo.one(
      from e in LedgerEntry,
        where: e.user_id == ^user_id,
        select: coalesce(sum(e.amount_cents), 0)
    ) || 0
  end

  # Waar een euro tegoed vandaan komt. Niet elke bijboeking is hetzelfde waard:
  # voor een `topup` is er geld binnengekomen, een `signup_bonus` hebben we
  # weggegeven, en een handmatige boeking is een beheerder die een getal
  # bijstelt. Ze staan in hetzelfde grootboek omdat ze alle drie bepalen wat een
  # klant kan uitgeven, maar ze bij elkaar optellen tot één bedrag maakt
  # testsaldo net zo echt als betaald saldo.
  @herkomst %{
    "topup" => :betaald,
    "signup_bonus" => :weggegeven,
    "admin_topup" => :handmatig,
    "admin_adjustment" => :handmatig,
    "correction" => :handmatig,
    "vps_charge" => :verbruikt,
    "vps_charge_refunded" => :verbruikt,
    "vps_refund" => :verbruikt
  }

  @doc """
  Het openstaande tegoed, uitgesplitst naar waar het vandaan komt.

  De som van de onderdelen is het totaal -- `:verbruikt` is negatief -- zodat het
  overzicht optelt tot hetzelfde bedrag dat er als verplichting op de balans
  staat.

  Een soort die hier niet in staat komt onder `:overig` terecht en niet in een
  bak waar hij toevallig op lijkt. Dat is het verschil tussen een overzicht dat
  een nieuwe boekingssoort laat zien en een overzicht dat hem stilzwijgend als
  betaald geld meetelt.
  """
  @spec saldo_naar_herkomst() :: %{atom() => integer()}
  def saldo_naar_herkomst do
    leeg = %{betaald: 0, weggegeven: 0, handmatig: 0, verbruikt: 0, overig: 0}

    Repo.all(
      from e in LedgerEntry,
        group_by: e.kind,
        select: {e.kind, coalesce(sum(e.amount_cents), 0)}
    )
    |> Enum.reduce(leeg, fn {kind, cents}, acc ->
      bak = Map.get(@herkomst, kind, :overig)
      Map.update!(acc, bak, &(&1 + cents))
    end)
  end

  @doc "Most recent ledger entries, newest first."
  def list_entries(user_id, limit \\ 20) do
    Repo.all(
      from e in LedgerEntry,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at],
        limit: ^limit
    )
  end

  @spec add_entry(binary(), integer(), String.t(), String.t() | nil, binary() | nil) ::
          {:ok, LedgerEntry.t()} | {:error, Ecto.Changeset.t()}
  def add_entry(user_id, amount_cents, kind, description, vps_id \\ nil) do
    %LedgerEntry{}
    |> LedgerEntry.changeset(%{
      user_id: user_id,
      vps_id: vps_id,
      amount_cents: amount_cents,
      kind: kind,
      description: description
    })
    |> Repo.insert()
  end

  @doc """
  Ties a charge to the VPS it paid for, once that VPS exists.

  A charge is taken before the machine is created — the wallet has to be checked
  and debited before anything is provisioned — so for a moment the entry has no
  VPS. Stamping it here closes that window: from now on a `vps_charge` still
  carrying no `vps_id` after the grace period means the creation never happened,
  and `Credits.refund_orphan_charges/1` can give the money back without anyone
  reading timestamps.
  """
  @spec attach_vps(LedgerEntry.t() | nil, binary()) ::
          {:ok, LedgerEntry.t() | nil} | {:error, Ecto.Changeset.t()}
  def attach_vps(nil, _vps_id), do: {:ok, nil}

  def attach_vps(%LedgerEntry{} = entry, vps_id) do
    entry |> LedgerEntry.changeset(%{vps_id: vps_id}) |> Repo.update()
  end

  @doc """
  Grants the one-time welcome credit, at most once per user.

  "One-time" is enforced against the ledger rather than assumed from the call
  site, because there are now two eras of account: users created before email
  confirmation existed were credited at registration and still have a NULL
  `confirmed_at`, so the moment one of them confirms their address,
  `Accounts.confirm_user/1` would hand them a second €10. Returns `{:ok, nil}`
  when a bonus is already on the ledger, which callers treat as success.
  """
  @spec grant_signup_bonus(binary()) :: {:ok, LedgerEntry.t() | :already_granted}
  def grant_signup_bonus(user_id) do
    already_granted? =
      Repo.exists?(
        from e in LedgerEntry, where: e.user_id == ^user_id and e.kind == "signup_bonus"
      )

    if already_granted? do
      {:ok, nil}
    else
      add_entry(user_id, @signup_bonus_cents, "signup_bonus", "Welkomstkrediet")
    end
  end

  @doc """
  Atomically charges `amount_cents` if the balance covers it. Returns
  `{:ok, entry}` or `{:error, :insufficient_credits}`. A zero/under charge is a
  no-op `{:ok, nil}` (free sizes never block creation).
  """
  @spec charge(binary(), integer(), String.t(), String.t()) ::
          {:ok, LedgerEntry.t() | nil} | {:error, :insufficient_credits}
  def charge(_user_id, amount_cents, _kind, _desc) when amount_cents <= 0, do: {:ok, nil}

  def charge(user_id, amount_cents, kind, description) do
    Repo.transaction(fn ->
      # Serialize per-user so two concurrent charges can't both observe the full
      # balance and overspend the wallet (mark_topup_paid/cancel already lock).
      :ok = ControlPlane.Locks.take(Repo, :wallet, user_id)

      if balance_cents(user_id) >= amount_cents do
        {:ok, entry} = add_entry(user_id, -amount_cents, kind, description)
        entry
      else
        Repo.rollback(:insufficient_credits)
      end
    end)
  end

  # Charges written before ledger_entries had a vps_id all carry nil, and nil is
  # what this sweep reads as "the VPS never existed". Without this floor it would
  # look at every charge the platform ever took and refund the lot — which is
  # exactly what happened the first time it ran, before this line existed.
  #
  # The date is when the column shipped. It is a constant rather than a lookup
  # because it is a fact about history, and history does not change.
  @vps_id_since ~U[2026-09-13 20:00:00.000000Z]

  @doc """
  Refunds every `vps_charge` that never got a VPS, and reports how many.

  This is the one failure the create path cannot handle itself. It debits the
  wallet, then creates the machine, and it wraps that in a rescue and a catch so
  an exception or an exit still refunds — but nothing rescues a `:kill` or a node
  that loses power between the two. What is left behind is a charge with no VPS,
  and before this existed the only way to find one was a person comparing
  timestamps in the ledger.

  `grace_seconds` is what separates "never happened" from "happening right now":
  a create in flight also has no `vps_id` yet, and refunding that would hand back
  money for a VPS the customer is about to receive.
  """
  @spec refund_orphan_charges(non_neg_integer()) :: non_neg_integer()
  def refund_orphan_charges(grace_seconds \\ 600) do
    # Not Clock.shift/1: ledger_entries timestamps carry microseconds, because
    # two movements in the same second still have an order and money cares about
    # it. Clock is for the second-precision columns everywhere else.
    cutoff = DateTime.add(DateTime.utc_now(), -grace_seconds, :second)

    orphans =
      Repo.all(
        from e in LedgerEntry,
          where:
            e.kind == "vps_charge" and is_nil(e.vps_id) and e.inserted_at < ^cutoff and
              e.inserted_at > ^@vps_id_since and e.amount_cents < 0
      )

    Enum.reduce(orphans, 0, fn entry, geteld ->
      case refund_failed_charge(entry, "Terugbetaling: de VPS is nooit aangemaakt") do
        {:ok, :already_refunded} ->
          # Een ander pad was ons voor. Niet tellen en niet loggen: dit is het
          # normale geval sinds de bestelweg zelf ook merkt.
          geteld

        {:ok, _} ->
          Logger.error(
            "refunded an orphaned vps_charge of #{abs(entry.amount_cents)} cents: " <>
              "the VPS it paid for was never created"
          )

          geteld + 1

        {:error, reden} ->
          Logger.error("terugbetaling van een verweesde afschrijving mislukte: #{inspect(reden)}")
          geteld
      end
    end)
  end

  @doc """
  Betaalt één afschrijving terug en merkt hem, in één transactie.

  De afschrijving voor een VPS gebeurt vóórdat die VPS bestaat, dus de regel
  heeft even geen `vps_id`. Precies daarop jaagt `refund_orphan_charges/1`. Wie
  vanuit de bestelweg terugbetaalt zonder de oorspronkelijke regel te merken,
  laat hem dus liggen voor de sweeper -- die tien minuten later hetzelfde bedrag
  nog eens uitbetaalt. Dat is op productie gebeurd: er stond meer terugbetaald
  dan er ooit was afgeschreven.

  De tegenboeking en de markering horen daarom bij elkaar. Twee losse writes met
  een deploy ertussen laten een terugbetaling zonder markering achter, en dan
  betaalt elke volgende tik opnieuw uit -- zonder bovengrens.

  De markering verandert `kind` van `"vps_charge"` naar `"vps_charge_refunded"`
  en raakt geen bedrag aan: het grootboek groeit, het wordt niet herschreven.

  Geeft `{:ok, :already_refunded}` voor een regel die al gemerkt is, zodat elke
  aanroeper hem gerust nog eens mag aanroepen.
  """
  @spec refund_failed_charge(LedgerEntry.t() | nil, String.t()) ::
          {:ok, LedgerEntry.t() | :already_refunded} | {:error, term()}
  def refund_failed_charge(entry, beschrijving \\ "Terugbetaling: VPS-aanmaak mislukt")

  def refund_failed_charge(nil, _beschrijving), do: {:ok, :already_refunded}

  def refund_failed_charge(%LedgerEntry{} = entry, beschrijving) do
    Repo.transaction(fn ->
      # Opnieuw lezen ONDER SLOT: twee paden kunnen tegelijk terugbetalen (de
      # bestelweg en de sweeper, of twee sweeps). Wie het slot krijgt en de
      # markering al ziet staan, doet niets meer.
      vers =
        Repo.one(
          from e in LedgerEntry,
            where: e.id == ^entry.id and e.kind == "vps_charge" and e.amount_cents < 0,
            lock: "FOR UPDATE"
        )

      case vers do
        nil ->
          :already_refunded

        gevonden ->
          {:ok, tegenboeking} =
            add_entry(
              gevonden.user_id,
              -gevonden.amount_cents,
              "vps_refund",
              beschrijving,
              gevonden.vps_id
            )

          {:ok, _} =
            gevonden |> LedgerEntry.changeset(%{kind: "vps_charge_refunded"}) |> Repo.update()

          tegenboeking
      end
    end)
  end

  @doc """
  Gives back what was charged for `vps_id`, once. Returns whether it found one.

  Idempotent by marking the original entry `vps_charge_refunded`: a sweep that
  runs every few seconds must not pay the same customer back on every tick.
  """
  @spec refund_charge_for_vps(binary()) :: boolean()
  def refund_charge_for_vps(vps_id) do
    case Repo.one(
           from e in LedgerEntry,
             where: e.vps_id == ^vps_id and e.kind == "vps_charge" and e.amount_cents < 0,
             # Een VPS met een abonnement heeft na een maand meer dan één
             # afschrijving. Terugbetaald wordt de bestelling: de eerste.
             order_by: [asc: e.inserted_at],
             limit: 1
         ) do
      nil ->
        false

      entry ->
        match?({:ok, %LedgerEntry{}}, refund_failed_charge(entry))
    end
  end

  @doc "Credits an amount back (e.g. refund a failed provision)."
  @spec refund(binary(), integer(), String.t(), String.t()) ::
          {:ok, LedgerEntry.t() | nil} | {:error, Ecto.Changeset.t()}
  def refund(_user_id, amount_cents, _kind, _desc) when amount_cents <= 0, do: {:ok, nil}

  def refund(user_id, amount_cents, kind, description),
    do: add_entry(user_id, amount_cents, kind, description)
end
