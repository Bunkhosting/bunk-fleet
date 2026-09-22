defmodule ControlPlaneWeb.MollieController do
  @moduledoc """
  Mollie-backed wallet top-ups.

    * POST /api/v1/billing/topup (authenticated) — creates a Mollie payment for
      the requested amount and returns its hosted checkout URL. A pending
      `topup_request` is recorded, keyed on the Mollie payment id.
    * POST /api/v1/billing/mollie/webhook (public) — Mollie calls this with a
      payment id. We FETCH the payment to verify it is really "paid" before
      crediting the wallet (idempotently). Always answers 200 so Mollie stops
      retrying; the credit work is safe to repeat.
  """
  use ControlPlaneWeb, :controller
  require Logger

  alias ControlPlane.Credits
  alias ControlPlane.Mollie
  alias ControlPlaneWeb.Fouten

  # Mollie states that mean the money will never arrive. Anything else is either
  # paid or still in flight, and a topup in flight stays pending.
  @unpaid_terminal ["expired", "canceled", "failed"]

  @min_cents 500
  @max_cents 100_000
  # A user can't stack unbounded unpaid checkouts: each one fans out an
  # authenticated create_payment call to Mollie and leaves a :pending row.
  @max_pending_topups 5

  def topup(conn, params) do
    user = conn.assigns.current_user

    # Eerst de rij, dan de betaling. Andersom -- zoals het hier stond -- is er een
    # moment waarop er bij Mollie een geldige betaalpagina klaarstaat waar wij
    # niets van weten: mislukt daarna de insert, of valt het proces om, dan
    # betaalt de klant en vindt de webhook niets. Dat is geld van een klant dat
    # nergens heen kan, en het enige spoor was een regel in een log.
    #
    # Een rij zonder betaling is het spiegelbeeld en veel onschuldiger: een
    # opwaardering die op :pending blijft staan en vanzelf verloopt.
    with {:ok, cents} <- parse_amount(params),
         true <- Mollie.configured?() || {:error, :not_configured},
         :ok <- check_pending_cap(user.id),
         {:ok, tr} <- Credits.create_topup_request(user.id, cents),
         {:ok, payment} <- vraag_betaling(tr, cents),
         {:ok, _} <- Credits.attach_mollie_payment(tr, payment.id) do
      json(conn, %{checkout_url: payment.checkout_url, payment_id: payment.id})
    else
      {:error, {:mollie_http, status, body}} when status in 400..499 ->
        # A 4xx from Mollie is a rejected request (e.g. an unregistered redirect
        # domain), not a gateway outage — surface the reason as 422 so it reaches
        # the client (Cloudflare replaces 5xx bodies with its own error page).
        detail = (is_map(body) && body["detail"]) || "betaling geweigerd"
        Logger.warning("mollie rejected topup: #{inspect(body)}")

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "payment_rejected", detail: detail})

      # Alles wat hierna komt is ofwel een reden die de tabel kent (een te klein
      # bedrag, te veel openstaande opwaarderingen, geen sleutel ingesteld),
      # ofwel iets onverwachts van de provider. Dat laatste is geen gat in onze
      # tabel maar een partij die iets anders doet dan afgesproken, en dan is 502
      # het eerlijke antwoord.
      anders ->
        Fouten.fout(conn, anders, onbekend: {:bad_gateway, "payment_provider_error"})
    end
  end

  # De betaling bij Mollie, met ons eigen id in de metadata. Dat id is het vangnet
  # voor het gat dat overblijft: valt het proces om ná deze aanroep en vóór
  # `attach_mollie_payment/2`, dan staat de rij er zonder Mollie-id -- en dan is
  # de metadata de enige manier waarop de webhook hem nog terugvindt.
  #
  # Mislukt de aanroep, dan wordt de zojuist aangemaakte rij weer weggehaald.
  # Laten staan zou hem tegen de limiet op openstaande opwaarderingen laten
  # tellen, en dan sluit een storing bij Mollie de klant buiten van zijn eigen
  # volgende poging. Wissen en niet annuleren, want er is niets gebeurd wat het
  # onthouden waard is: er bestaat geen betaling, dus er valt ook niets tegen te
  # boeken. Een geannuleerde rij zou alleen zijn overzicht vervuilen met iets wat
  # hij niet heeft gedaan.
  defp vraag_betaling(tr, cents) do
    case Mollie.create_payment(%{
           amount_cents: cents,
           description: "Bunk Hosting tegoed",
           redirect_url: public_url() <> "/dashboard/billing?topup=processing",
           webhook_url: public_url() <> "/api/v1/billing/mollie/webhook",
           metadata: %{user_id: tr.user_id, topup_id: tr.id}
         }) do
      {:ok, payment} ->
        {:ok, payment}

      {:error, reden} ->
        Credits.delete_topup_request(tr)
        {:error, reden}
    end
  end

  def webhook(conn, %{"id" => payment_id}) when is_binary(payment_id) do
    # Validate the id shape BEFORE any outbound fetch: rejects malformed ids (path
    # smuggling into the Mollie API) and cheap garbage that would otherwise fan out
    # one authenticated HTTPS call to Mollie per request.
    if valid_mollie_id?(payment_id),
      do: settle(payment_id, Mollie.get_payment(payment_id)),
      else: Logger.info("mollie webhook: ignoring malformed payment id")

    # Always 200: the work is idempotent and we don't want Mollie to retry on our
    # transient errors forever in a way that hammers us.
    send_resp(conn, 200, "")
  end

  def webhook(conn, _params), do: send_resp(conn, 200, "")

  # What Mollie says the payment did. The webhook itself carries no state — it is
  # only a nudge to re-fetch — so everything below is driven by the fetch.
  defp settle(payment_id, {:ok, %{status: "paid", amount: amount} = betaling}) do
    # Credit only after verifying the amount Mollie actually settled matches the
    # amount we recorded — defence-in-depth against adjustable-amount payment
    # types ever being enabled.
    credited(payment_id, bijschrijven(payment_id, amount, betaling[:metadata]))
  end

  defp settle(payment_id, {:ok, %{status: status}}) when status in @unpaid_terminal do
    # Terminal, unpaid: release the pending row so it stops counting against the
    # user's pending-topup cap.
    Credits.cancel_topup_by_mollie_id(payment_id)
    Logger.info("mollie webhook #{payment_id} status=#{status} (topup cancelled)")
  end

  defp settle(payment_id, {:ok, %{status: status}}),
    do: Logger.info("mollie webhook #{payment_id} status=#{status} (no credit)")

  defp settle(payment_id, {:error, reason}),
    do: Logger.warning("mollie webhook fetch failed for #{payment_id}: #{inspect(reason)}")

  # Normaal wordt de rij gevonden op het Mollie-id. Staat die er niet, dan is er
  # één geval waarin dat geen verloren betaling is: het proces viel om tussen het
  # aanmaken van de betaling en het vastleggen van het id. De rij bestaat dan wel,
  # en ons eigen id zit in de metadata die wij aan de betaling hebben meegegeven.
  #
  # Dat is veilig om te vertrouwen: de metadata komt niet van de webhook maar uit
  # de betaling die we zojuist bij Mollie hebben opgehaald, en we kijken er pas
  # naar nadat die betaling op "paid" stond.
  defp bijschrijven(payment_id, amount, metadata) do
    if Mollie.live_sleutel?() do
      bijschrijven_echt(payment_id, amount, metadata)
    else
      {:error, :testsleutel}
    end
  end

  defp bijschrijven_echt(payment_id, amount, metadata) do
    case Credits.mark_topup_paid_by_mollie_id(payment_id, amount) do
      {:error, :not_found} ->
        case metadata do
          %{"topup_id" => topup_id} when is_binary(topup_id) ->
            Logger.warning(
              "mollie webhook #{payment_id}: geen rij op het betaal-id, teruggevallen op topup_id uit de metadata"
            )

            Credits.mark_topup_paid_by_id(topup_id, amount)

          _ ->
            {:error, :not_found}
        end

      anders ->
        anders
    end
  end

  defp credited(_payment_id, {:ok, _}), do: :ok

  # Een betaling in Mollie's testmodus ziet er in elk antwoord identiek uit aan
  # een echte, inclusief "paid". Het enige verschil is de sleutel waarmee hij is
  # aangemaakt. Zou dit tegoed opleveren, dan komt er geld uit het niets -- en
  # dat is in de eerste weken ook echt gebeurd: er stond duizenden euro's aan
  # saldo waar nooit iets voor is betaald.
  #
  # De opwaardering blijft op :pending staan. Dat is eerlijker dan hem op betaald
  # zetten zonder bij te schrijven: er is niets betaald.
  defp credited(payment_id, {:error, :testsleutel}) do
    Logger.error(
      "mollie webhook: betaling #{payment_id} kwam binnen op een TESTSLEUTEL; er is niets bijgeschreven"
    )

    ControlPlane.Notifier.deliver_operational_alert(
      "Mollie draait op een testsleutel",
      """
      Er kwam een betaalde webhook binnen (#{payment_id}), maar MOLLIE_API_KEY is
      geen live-sleutel. Er is dus niets bijgeschreven, en dat is de bedoeling:
      een testbetaling die echt tegoed oplevert is geld uit het niets.

      Draait dit op productie, dan staat de verkeerde sleutel in .env.prod en kan
      op dit moment niemand opwaarderen. Draait het ergens anders, dan klopt het.
      """
    )
  end

  defp credited(_payment_id, {:error, :not_pending}), do: :ok

  # A verified *paid* payment with no matching topup row means a real customer
  # payment we can't reconcile — never swallow it silently.
  defp credited(payment_id, {:error, :not_found}) do
    Logger.error(
      "mollie webhook: PAID payment #{payment_id} has no matching topup_request — possible lost payment, reconcile manually"
    )

    # Een `Logger.error` in een container is geen afhandeling. Dit is het enige
    # geval in het hele systeem waarin iemand geld heeft betaald en er niets
    # tegenover staat; dat hoort iemand te weten zonder dat hij toevallig in de
    # logs keek.
    ControlPlane.Notifier.deliver_operational_alert(
      "Betaling ontvangen zonder bijbehorende opwaardering",
      """
      Mollie meldt dat betaling #{payment_id} betaald is, maar er staat geen
      opwaardering tegenover -- niet op het betaal-id en niet op het id in de
      metadata.

      De klant heeft betaald en heeft geen tegoed gekregen. Zoek de betaling op in
      het Mollie-dashboard (bedrag, e-mailadres, tijdstip), zoek de gebruiker
      erbij en boek het tegoed met de hand bij.

      Dit hoort niet voor te komen: sinds de opwaardering wordt vastgelegd vóórdat
      de betaling wordt aangemaakt, bestaat de rij al voordat de klant kan
      betalen. Komt dit toch langs, kijk dan of iemand rechtstreeks bij Mollie
      een betaling heeft aangemaakt, of dat er is teruggerold naar een oudere
      versie.
      """
    )
  end

  defp credited(payment_id, {:error, :amount_mismatch}),
    do: Logger.error("mollie webhook amount mismatch for #{payment_id}")

  defp credited(_payment_id, other),
    do: Logger.warning("mollie webhook credit: #{inspect(other)}")

  # Mollie payment ids look like `tr_<alnum>`.
  defp valid_mollie_id?(id), do: String.match?(id, ~r/\Atr_[A-Za-z0-9]+\z/)

  defp parse_amount(%{"amount_cents" => v}) do
    cents =
      cond do
        is_integer(v) ->
          v

        is_binary(v) ->
          case Integer.parse(v) do
            {n, ""} -> n
            _ -> nil
          end

        true ->
          nil
      end

    if is_integer(cents) and cents >= @min_cents and cents <= @max_cents,
      do: {:ok, cents},
      else: {:error, :invalid_amount}
  end

  defp parse_amount(_), do: {:error, :invalid_amount}

  defp check_pending_cap(user_id) do
    if Credits.count_pending_topups(user_id) >= @max_pending_topups,
      do: {:error, :too_many_pending},
      else: :ok
  end

  defp public_url, do: Application.get_env(:control_plane, :public_url) || ""
end
