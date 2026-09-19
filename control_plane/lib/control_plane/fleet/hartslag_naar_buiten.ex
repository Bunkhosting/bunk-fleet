defmodule ControlPlane.Fleet.HartslagNaarBuiten do
  @moduledoc """
  Meldt aan een buitenstaander dat het control plane nog leeft.

  Alles wat Bunk over zichzelf weet, weet Bunk vanuit zichzelf. Er is een
  schijfalarm, er zijn operationele mails, er is een `/healthz` -- en alle drie
  gaan ze stil op het moment dat het control plane niet meer draait. Dan is er
  niemand meer die iets kan melden, en precies dan zou er iemand moeten piepen.

  Dat is wat een dead-man-switch oplost, en hij werkt averechts om: niet "wij
  melden dat het misgaat" maar "wij melden dat het goed gaat, en als dat bericht
  uitblijft weet iemand anders genoeg". Het uitblijven van een signaal is het
  enige signaal dat een omgevallen systeem nog kan geven.

  ## Wat "leeft" hier betekent

  Niet "het proces bestaat". Een reconciler die elke tik omvalt op een
  onbereikbare database bestaat ook, en die hoort geen levensteken te geven.
  Daarom wordt er eerst een triviale vraag aan de database gesteld; pas als die
  wordt beantwoord gaat het bericht de deur uit.

  ## Uit tot iemand een adres invult

  Zonder `DEADMAN_URL` doet dit niets, en dat staat één keer in de log zodat
  "staat uit" en "werkt" niet op elkaar lijken. De dienst erachter (een
  ping-dienst, een eigen scriptje op een andere machine) is een keuze van de
  beheerder; deze module heeft alleen een adres nodig.

  Het bericht gaat er hooguit één keer per minuut uit, niet elke tik van dertig
  seconden. Een dead-man-switch die twee keer zo vaak pingt als nodig levert geen
  extra zekerheid op, alleen twee keer zoveel verkeer naar een derde partij.
  """
  require Logger

  alias ControlPlane.Repo

  @min_interval_ms 60_000

  @doc """
  Zegt bij het opstarten één keer of deze switch aan of uit staat.

  Zonder deze regel lijkt "er is nooit een adres ingesteld" op "het werkt
  prima": in allebei de gevallen is het stil in de log. Dat is precies het soort
  stilte waarin een vangnet jarenlang niet blijkt te bestaan.
  """
  @spec meld_stand() :: :ok
  def meld_stand do
    case url() do
      nil ->
        Logger.info("dead-man-switch staat uit: DEADMAN_URL is niet gezet")

      _ ->
        Logger.info("dead-man-switch staat aan; levensteken hooguit eens per minuut")
    end

    :ok
  end

  @doc """
  Stuurt een levensteken als er een adres is ingesteld en de database antwoordt.

  `laatste` is het monotone tijdstip van de vorige poging (of `nil`); de
  teruggegeven waarde hoort daarvoor in de plaats te komen.
  """
  @spec piep(integer() | nil) :: integer() | nil
  def piep(laatste) do
    now = System.monotonic_time(:millisecond)

    cond do
      is_nil(url()) -> laatste
      not is_nil(laatste) and now - laatste < @min_interval_ms -> laatste
      true -> stuur(url(), now, laatste)
    end
  end

  defp stuur(url, now, laatste) do
    if database_antwoordt?() do
      verzend(url)
      now
    else
      # Bewust geen levensteken: dit is precies het geval waarvoor de switch
      # bestaat. Het tijdstip blijft staan, zodat de volgende tik het opnieuw
      # probeert in plaats van een minuut te wachten.
      Logger.warning("dead-man-switch: geen levensteken gestuurd, de database antwoordde niet")
      laatste
    end
  end

  # Een korte time-out en geen herhaling: dit mag de klok nooit ophouden. Een
  # gemiste ping is niet erg -- de dienst erachter hoort pas te alarmeren na een
  # ruime marge -- maar een reconciler die vastloopt op een traag adres neemt
  # metering, facturatie en back-ups mee.
  defp verzend(url) do
    case Req.get(url, receive_timeout: 3_000, connect_options: [timeout: 2_000], retry: false) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        Logger.warning("dead-man-switch: het adres antwoordde met #{status}")

      {:error, reden} ->
        Logger.warning("dead-man-switch: adres niet bereikbaar (#{inspect(reden)})")
    end
  rescue
    exception ->
      Logger.warning("dead-man-switch: versturen mislukt: #{Exception.message(exception)}")
  end

  defp database_antwoordt? do
    match?({:ok, _}, Repo.query("SELECT 1", [], timeout: 2_000))
  rescue
    _ -> false
  catch
    # Een uitgeputte pool komt als exit binnen, niet als exception.
    :exit, _ -> false
  end

  defp url do
    case Application.get_env(:control_plane, :deadman_url) do
      adres when is_binary(adres) ->
        schoon = String.trim(adres)
        if schoon == "", do: nil, else: schoon

      _ ->
        nil
    end
  end
end
