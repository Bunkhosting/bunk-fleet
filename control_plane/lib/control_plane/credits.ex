defmodule ControlPlane.Credits do
  @moduledoc """
  Prepaid customer credit wallet — the internal stand-in for a real payment
  provider (Mollie comes later). Each user's balance is the sum of a signed
  `ledger_entries` log (integer cents; positive = credit, negative = charge).

  New users receive a signup bonus; creating a VPS charges a flat monthly price
  by size. This is the *customer-facing* side only — internal cost accounting uses the
  separate per-resource-hour metering in `ControlPlane.Billing`.
  """
  import Ecto.Query

  require Logger
  alias ControlPlane.Clock
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Credits.TopupRequest
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

  ## Top-up requests (self-service wallet funding; admin confirms receipt)

  @doc """
  Creates a pending top-up request with a unique payment reference.

  Dit is ook de eerste stap van een Mollie-opwaardering, en die volgorde is het
  punt: eerst bij Mollie een betaling aanmaken en dan pas hier een rij
  wegschrijven betekent dat een mislukte insert -- of een proces dat omvalt
  tussen de twee -- een geldige betaalpagina achterlaat in de browser van de
  klant. Hij betaalt, en de webhook vindt niets. Andersom is het ergste geval een
  rij die nooit betaald wordt, en dat is precies wat `:pending` betekent.

  Zie `attach_mollie_payment/2` voor de tweede stap.
  """
  def create_topup_request(user_id, amount_cents) do
    %TopupRequest{}
    |> TopupRequest.changeset(%{
      user_id: user_id,
      amount_cents: amount_cents,
      reference: generate_reference(),
      status: :pending
    })
    |> Repo.insert()
  end

  def list_topup_requests(user_id, limit \\ 20) do
    Repo.all(
      from t in TopupRequest,
        where: t.user_id == ^user_id,
        order_by: [desc: t.inserted_at],
        limit: ^limit
    )
  end

  @doc "All pending requests (admin queue), oldest first, with the user preloaded."
  def list_pending_topups do
    Repo.all(
      from t in TopupRequest,
        where: t.status == :pending,
        order_by: [asc: t.inserted_at],
        preload: [:user]
    )
  end

  @doc "Number of still-pending top-up requests for a user (used to cap abuse)."
  @spec count_pending_topups(binary()) :: non_neg_integer()
  def count_pending_topups(user_id) do
    Repo.aggregate(
      from(t in TopupRequest, where: t.user_id == ^user_id and t.status == :pending),
      :count
    )
  end

  @doc """
  Confirms a pending top-up: credits the wallet and marks the request paid,
  atomically. A non-pending request yields `{:error, :not_pending}` so a
  double-confirm can never double-credit.

  `paid_via` legt vast wie de betaling bevestigde: `"mollie"` voor de webhook van
  de betaalprovider, `"manual"` voor een mens. Dat onderscheid bepaalt of het
  bedrag omzet is — zie `ControlPlane.Billing.Revenue` — en het is daarom een
  verplicht argument in plaats van iets met een voorkeurswaarde. Een nieuwe
  aanroeper moet die vraag beantwoorden, niet per ongeluk overslaan.
  """
  def mark_topup_paid(id, paid_via) when paid_via in ["mollie", "manual"] do
    Repo.transaction(fn ->
      # Lock the row so two concurrent confirms can't both observe :pending and
      # credit the wallet twice (READ COMMITTED would otherwise allow it).
      case Repo.one(from t in TopupRequest, where: t.id == ^id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        %TopupRequest{status: :pending} = tr ->
          {:ok, _} =
            add_entry(
              tr.user_id,
              tr.amount_cents,
              "topup",
              "Tegoed bijgeboekt (" <> tr.reference <> ")"
            )

          {:ok, tr} =
            tr
            |> Ecto.Changeset.change(
              status: :paid,
              paid_at: Clock.now(),
              paid_via: paid_via
            )
            |> Repo.update()

          tr

        _ ->
          Repo.rollback(:not_pending)
      end
    end)
  end

  @doc "Lets a user cancel their own still-pending request."
  def cancel_topup_request(user_id, id) do
    Repo.transaction(fn ->
      case Repo.one(from t in TopupRequest, where: t.id == ^id, lock: "FOR UPDATE") do
        %TopupRequest{user_id: ^user_id, status: :pending} = tr ->
          {:ok, tr} = tr |> Ecto.Changeset.change(status: :cancelled) |> Repo.update()
          tr

        _ ->
          Repo.rollback(:not_cancellable)
      end
    end)
  end

  @doc "Creates a pending top-up backed by a Mollie payment, keyed on its id."
  def create_mollie_topup(user_id, amount_cents, mollie_payment_id) do
    %TopupRequest{}
    |> TopupRequest.changeset(%{
      user_id: user_id,
      amount_cents: amount_cents,
      reference: mollie_payment_id,
      mollie_payment_id: mollie_payment_id,
      status: :pending
    })
    |> Repo.insert()
  end

  @doc """
  Haalt een opwaardering weg die nooit een betaling heeft gekregen.

  Alleen voor de rij die net is aangemaakt en waarvoor het aanmaken van de
  betaling mislukte: er bestaat dan geen betaling, dus er valt ook nooit iets
  tegen te boeken. Guard op `:pending`, zodat dit nooit een betaalde opwaardering
  kan raken.
  """
  @spec delete_topup_request(TopupRequest.t()) :: :ok
  def delete_topup_request(%TopupRequest{status: :pending} = tr) do
    Repo.delete(tr)
    :ok
  end

  def delete_topup_request(%TopupRequest{}), do: :ok

  @doc """
  Hangt het Mollie-betaal-id aan een eerder vastgelegde opwaardering.

  Lukt dit niet -- het proces valt om tussen het aanmaken van de betaling en deze
  regel -- dan blijft de rij zonder id staan. De webhook kan hem dan nog altijd
  vinden via het `topup_id` in de metadata van de betaling; zie
  `mark_topup_paid_by_id/2`.
  """
  @spec attach_mollie_payment(TopupRequest.t(), binary()) ::
          {:ok, TopupRequest.t()} | {:error, Ecto.Changeset.t()}
  def attach_mollie_payment(%TopupRequest{} = tr, mollie_payment_id) do
    tr
    |> TopupRequest.changeset(%{
      mollie_payment_id: mollie_payment_id,
      reference: mollie_payment_id
    })
    |> Repo.update()
  end

  @doc """
  Zoals `mark_topup_paid_by_mollie_id/2`, maar op onze eigen id.

  Dit is het vangnet voor de rij waar nooit een Mollie-id aan gehangen is. Het
  id komt uit de metadata die wij zelf aan de betaling hebben meegegeven, dus het
  komt langs Mollie terug zonder dat iemand anders het kan kiezen -- en het wordt
  pas gebruikt nadat de betaling bij Mollie is opgehaald en op "paid" stond.
  """
  @spec mark_topup_paid_by_id(binary(), map() | nil) ::
          {:ok, term()} | {:error, atom()}
  def mark_topup_paid_by_id(topup_id, paid_amount \\ nil) do
    case Repo.get(TopupRequest, topup_id) do
      nil ->
        {:error, :not_found}

      %TopupRequest{} = tr ->
        if amount_matches?(tr, paid_amount),
          do: mark_topup_paid(tr.id, "mollie"),
          else: {:error, :amount_mismatch}
    end
  rescue
    # Een id uit metadata hoeft geen geldige UUID te zijn.
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Credits the wallet for a paid Mollie payment (idempotent via mark_topup_paid).
  When `paid_amount` (Mollie's `%{"value","currency"}`) is given, the settled
  amount must match the recorded request or it is rejected `:amount_mismatch`.
  """
  def mark_topup_paid_by_mollie_id(mollie_payment_id, paid_amount \\ nil) do
    case Repo.get_by(TopupRequest, mollie_payment_id: mollie_payment_id) do
      nil ->
        {:error, :not_found}

      %TopupRequest{} = tr ->
        if amount_matches?(tr, paid_amount),
          do: mark_topup_paid(tr.id, "mollie"),
          else: {:error, :amount_mismatch}
    end
  end

  # Mollie draait sinds dit moment op een live-sleutel. Wat daarvoor is
  # aangemaakt hoort bij de testmodus: die betaal-ids bestaan niet in de
  # live-omgeving, dus een verzoening zou ze eindeloos opvragen en eindeloos
  # niet vinden. Net als `@vps_id_since` hierboven is dit een feit over de
  # geschiedenis, en de geschiedenis verandert niet.
  @mollie_live_sinds ~U[2026-09-14 00:00:00.000000Z]

  @doc """
  Opwaarderingen die nog open staan en waarvan Mollie de uitkomst weet.

  Alleen rijen met een betaal-id: zonder dat id heeft de klant nooit een
  betaalpagina gezien en kan er ook niets binnenkomen. En alleen rijen die al
  even staan, zodat een klant die op dit moment bij zijn bank staat niet wordt
  opgejaagd door een tweede vraag aan Mollie over dezelfde betaling.
  """
  @spec openstaande_topups_om_te_verzoenen(non_neg_integer()) :: [TopupRequest.t()]
  def openstaande_topups_om_te_verzoenen(ouder_dan_seconden) do
    grens = DateTime.add(DateTime.utc_now(), -ouder_dan_seconden, :second)

    Repo.all(
      from t in TopupRequest,
        where:
          t.status == :pending and not is_nil(t.mollie_payment_id) and
            t.inserted_at < ^grens and t.inserted_at > ^@mollie_live_sinds,
        order_by: [asc: t.inserted_at]
    )
  end

  @doc """
  Marks a pending top-up `:cancelled` by its Mollie id (payment expired/canceled/
  failed). Idempotent and guarded on `:pending`, so it frees the per-user pending
  cap without ever touching an already-paid credit.
  """
  def cancel_topup_by_mollie_id(mollie_payment_id) do
    {count, _} =
      from(t in TopupRequest,
        where: t.mollie_payment_id == ^mollie_payment_id and t.status == :pending
      )
      |> Repo.update_all(set: [status: :cancelled, updated_at: Clock.now()])

    if count == 1, do: :ok, else: {:error, :not_pending}
  end

  # No amount to check against → accept (back-compat / admin flow).
  defp amount_matches?(_tr, nil), do: true

  defp amount_matches?(%TopupRequest{amount_cents: cents}, %{
         "value" => value,
         "currency" => currency
       }) do
    currency == "EUR" and value == euro_string(cents)
  end

  defp amount_matches?(_tr, _), do: false

  # Integer cents -> Mollie's 2-decimal string, matching ControlPlane.Mollie.
  defp euro_string(cents) when is_integer(cents) and cents >= 0 do
    "#{div(cents, 100)}." <>
      (rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0"))
  end

  defp generate_reference do
    rand = :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 8)
    "BUNK-" <> rand
  end
end
