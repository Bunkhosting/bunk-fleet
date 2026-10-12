defmodule ControlPlane.Credits.Topups do
  @moduledoc """
  Opwaarderen van het tegoed: de verzoeken waarmee een klant geld op zijn
  wallet zet, via Mollie of handmatig door een beheerder bevestigd.

  Een opwaardering begint als `TopupRequest` op `:pending` met een unieke
  betaalreferentie (`create_topup_request/2`), krijgt daarna het Mollie-betaal-id
  (`attach_mollie_payment/2`) en wordt betaald (`mark_topup_paid/2` en de
  varianten op Mollie-id of eigen id) of geannuleerd. Alleen het betalen raakt
  het grootboek, en dat via `ControlPlane.Credits.add_entry/5` binnen dezelfde
  transactie waarin de rij onder slot op `:paid` gaat -- zodat een dubbele
  bevestiging nooit dubbel bijboekt.

  Het grootboek zelf -- saldo, afschrijvingen en terugbetalingen -- blijft in
  `ControlPlane.Credits`.
  """
  import Ecto.Query

  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Repo

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

  @doc """
  Number of still-pending top-up requests for a user (used to cap abuse).

  Een rij zonder Mollie-id telt na een uur niet meer mee. Die ontstaat als het
  proces omvalt tussen het aanmaken van de betaling en het vastleggen van het
  id. De verzoening kan hem niet nalopen (er is geen id om naar te vragen) en
  een annulering van Mollie vindt hem niet, dus hij bleef voorgoed op :pending
  staan -- en vijf daarvan sloten een klant buiten van opwaarderen. Hij wordt
  niet geannuleerd: een betaald-webhook vindt hem nog via de metadata.
  """
  @spec count_pending_topups(binary()) :: non_neg_integer()
  def count_pending_topups(user_id) do
    zonder_id_telt_tot = DateTime.add(DateTime.utc_now(), -3600, :second)

    Repo.aggregate(
      from(t in TopupRequest,
        where:
          t.user_id == ^user_id and t.status == :pending and
            (not is_nil(t.mollie_payment_id) or t.inserted_at > ^zonder_id_telt_tot)
      ),
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
            Credits.add_entry(
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
  # niet vinden. Net als `@vps_id_since` in `ControlPlane.Credits` is dit een
  # feit over de geschiedenis, en de geschiedenis verandert niet.
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
