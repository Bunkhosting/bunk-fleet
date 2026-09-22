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

  alias ControlPlane.Billing.MollieAfhandeling
  alias ControlPlane.Credits
  alias ControlPlane.Mollie
  alias ControlPlaneWeb.Fouten

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
      do: MollieAfhandeling.afhandelen(payment_id, Mollie.get_payment(payment_id), "webhook"),
      else: Logger.info("mollie webhook: ignoring malformed payment id")

    # Always 200: the work is idempotent and we don't want Mollie to retry on our
    # transient errors forever in a way that hammers us.
    send_resp(conn, 200, "")
  end

  def webhook(conn, _params), do: send_resp(conn, 200, "")

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
