defmodule ControlPlane.Billing.MollieAfhandeling do
  @moduledoc """
  Wat er met een Mollie-betaling gebeurt zodra we weten wat hij deed.

  Dit stond in `MollieController` en werkte daar prima, met één beperking: een
  controller draait alleen als iemand hem aanroept. De enige die dat deed was
  Mollie's webhook, en daarmee hing het hele geldpad aan één HTTP-verzoek van
  buiten. Komt dat verzoek niet aan -- de tunnel lag er even uit, een uitrol
  viel er precies overheen, Mollie gaf het op na zijn laatste poging -- dan
  heeft een klant betaald en staat er niets op zijn tegoed. Niemand merkt het,
  want er is geen tweede kans: er was maar één trigger.

  Sinds deze module hier staat zijn het er twee. De webhook blijft de snelle
  weg, en `verzoen/1` loopt periodiek de opwaarderingen na die nog openstaan en
  vraagt Mollie alsnog wat ze deden. Beide komen op dezelfde plek uit, dus er is
  geen tweede versie van de regels die over geld gaan.

  ## Waarom Mollie het laatste woord heeft

  Wat hier binnenkomt is niet wat de webhook zegt maar wat een opgehaalde
  betaling zegt. De webhook draagt geen toestand; hij is een seintje dat je moet
  gaan kijken. Datzelfde geldt voor de verzoening: die gokt nooit op grond van
  ouderdom dat iets wel mislukt zal zijn, want een rij afsluiten die daarna
  alsnog betaald wordt, is geld van een klant weggooien.
  """
  require Logger

  alias ControlPlane.Credits
  alias ControlPlane.Mollie

  # Mollie states that mean the money will never arrive. Anything else is either
  # paid or still in flight, and a topup in flight stays pending.
  @unpaid_terminal ["expired", "canceled", "failed"]

  @doc """
  Vraagt Mollie alsnog wat er is gebeurd met opwaarderingen die blijven staan.

  Bedoeld voor de klok, niet voor een verzoek van een klant: hij doet één
  uitgaande aanroep per openstaande rij. Dat aantal is begrensd -- een klant mag
  er vijf tegelijk open hebben staan -- maar het is niet gratis, dus het draait
  op een eigen, ruime slag.

  `ouder_dan_seconden` houdt de betalingen erbuiten die nog gewoon aan de gang
  zijn. Wie op dit moment bij zijn bank staat, is niet "blijven staan".

  Er staat met opzet geen bovengrens tegenover: een rij die na een maand nog
  openstaat, wordt nog steeds nagevraagd. Een bovengrens zou hem stilletjes uit
  beeld halen en voorgoed laten staan, en dat is precies het soort gat dat deze
  module moet dichten. Betalingen lopen vanzelf dood -- Mollie zet ze op
  "expired" en dan sluit de rij zich -- dus het blijft vanzelf een handvol.

  Geeft terug hoeveel rijen zijn nagevraagd. Wat die navraag oplevert staat in
  de logs, want dat is per rij iets anders en alleen de bijschrijvingen zijn
  nieuws.
  """
  @spec verzoen(non_neg_integer()) :: non_neg_integer()
  def verzoen(ouder_dan_seconden \\ 900) do
    openstaand = Credits.openstaande_topups_om_te_verzoenen(ouder_dan_seconden)

    Enum.each(openstaand, fn topup ->
      afhandelen(
        topup.mollie_payment_id,
        Mollie.get_payment(topup.mollie_payment_id),
        "verzoening"
      )
    end)

    length(openstaand)
  end

  @doc """
  Handelt één betaling af op grond van wat Mollie erover zegt.

  `bron` staat alleen in de logregels en zegt wie het vroeg -- de webhook of de
  verzoening. Dat verschil is de moeite waard: een betaling die door de
  verzoening wordt bijgeschreven betekent dat er een webhook is kwijtgeraakt, en
  dat is een feit over onze bereikbaarheid dat je anders nooit ziet.
  """
  @spec afhandelen(String.t(), {:ok, map()} | {:error, term()}, String.t()) :: :ok
  def afhandelen(payment_id, uitkomst, bron \\ "webhook")

  # What Mollie says the payment did. The webhook itself carries no state — it is
  # only a nudge to re-fetch — so everything below is driven by the fetch.
  def afhandelen(payment_id, {:ok, %{status: "paid", amount: amount} = betaling}, bron) do
    # Credit only after verifying the amount Mollie actually settled matches the
    # amount we recorded — defence-in-depth against adjustable-amount payment
    # types ever being enabled.
    credited(payment_id, bijschrijven(payment_id, amount, betaling[:metadata]), bron)
  end

  def afhandelen(payment_id, {:ok, %{status: status}}, bron) when status in @unpaid_terminal do
    # Terminal, unpaid: release the pending row so it stops counting against the
    # user's pending-topup cap.
    Credits.cancel_topup_by_mollie_id(payment_id)
    Logger.info("mollie #{bron} #{payment_id} status=#{status} (topup cancelled)")
  end

  def afhandelen(payment_id, {:ok, %{status: status}}, bron),
    do: Logger.info("mollie #{bron} #{payment_id} status=#{status} (no credit)")

  def afhandelen(payment_id, {:error, reason}, bron),
    do: Logger.warning("mollie #{bron} fetch failed for #{payment_id}: #{inspect(reason)}")

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
              "mollie #{payment_id}: geen rij op het betaal-id, teruggevallen op topup_id uit de metadata"
            )

            Credits.mark_topup_paid_by_id(topup_id, amount)

          _ ->
            {:error, :not_found}
        end

      anders ->
        anders
    end
  end

  defp credited(payment_id, {:ok, _}, bron) do
    # Alleen zeggen als de verzoening het deed. Dan is er een webhook
    # kwijtgeraakt, en dat wil je weten: het zegt iets over hoe goed wij van
    # buiten bereikbaar zijn, en dat zie je nergens anders aan.
    if bron != "webhook" do
      Logger.warning(
        "mollie #{bron}: betaling #{payment_id} alsnog bijgeschreven -- " <>
          "de webhook hiervoor is nooit aangekomen"
      )
    end

    :ok
  end

  # Een betaling in Mollie's testmodus ziet er in elk antwoord identiek uit aan
  # een echte, inclusief "paid". Het enige verschil is de sleutel waarmee hij is
  # aangemaakt. Zou dit tegoed opleveren, dan komt er geld uit het niets -- en
  # dat is in de eerste weken ook echt gebeurd: er stond duizenden euro's aan
  # saldo waar nooit iets voor is betaald.
  #
  # De opwaardering blijft op :pending staan. Dat is eerlijker dan hem op betaald
  # zetten zonder bij te schrijven: er is niets betaald.
  defp credited(payment_id, {:error, :testsleutel}, bron) do
    Logger.error(
      "mollie #{bron}: betaling #{payment_id} kwam binnen op een TESTSLEUTEL; er is niets bijgeschreven"
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

    :ok
  end

  defp credited(_payment_id, {:error, :not_pending}, _bron), do: :ok

  # A verified *paid* payment with no matching topup row means a real customer
  # payment we can't reconcile — never swallow it silently.
  defp credited(payment_id, {:error, :not_found}, bron) do
    Logger.error(
      "mollie #{bron}: PAID payment #{payment_id} has no matching topup_request — possible lost payment, reconcile manually"
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

    :ok
  end

  defp credited(payment_id, {:error, :amount_mismatch}, bron),
    do: Logger.error("mollie #{bron} amount mismatch for #{payment_id}")

  defp credited(_payment_id, other, bron),
    do: Logger.warning("mollie #{bron} credit: #{inspect(other)}")
end
