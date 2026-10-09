defmodule ControlPlane.Idempotency do
  @moduledoc """
  Zorgt dat een verzoek dat twee keer binnenkomt één keer wordt uitgevoerd.

  Het geval waar dit voor bestaat: een klant klikt op bestellen, de verbinding
  valt weg vlak voordat het antwoord terugkomt, en hij probeert het opnieuw. Het
  control plane ziet twee volwaardige verzoeken en maakt twee VPS'en aan met twee
  afschrijvingen. De klant merkt dat pas op zijn rekening.

  De sleutel komt van de client, want alleen die weet dat twee verzoeken
  dezelfde bedoeling hebben. Zonder sleutel gedraagt alles zich als voorheen --
  een oudere client of een curl-aanroep hoort niet te breken omdat wij iets
  hebben toegevoegd.

  ## Waarom de database en niet het geheugen

  Een uitrol tussen de twee verzoeken is precies het moment waarop dit gebeurt.
  Een ETS-tabel of de state van een proces is dan leeg, en de bescherming die je
  het hardst nodig had bestond net niet meer. De unieke index doet het werk: twee
  gelijktijdige verzoeken kunnen niet allebei dezelfde rij aanmaken.

  ## Drie uitkomsten

    * `{:ok, {:claimed, rij}}` -- dit verzoek mag het werk doen; geef `rij`
      later mee aan `finish/2` of `release/1`.
    * `{:ok, {:done, vps_id}}` -- ditzelfde verzoek is al gelukt; geef dat
      resultaat terug in plaats van het nog eens te doen.
    * `{:ok, :zonder_sleutel}` -- er was geen sleutel (of hij is intussen
      verdwenen); doe het werk zonder bescherming, zoals voorheen.
    * `{:error, :in_flight}` -- een eerder verzoek met deze sleutel is nog bezig.
      Niet opnieuw beginnen en ook geen resultaat verzinnen: de klant hoort te
      wachten.
  """
  import Ecto.Query

  alias ControlPlane.Idempotency.Key
  alias ControlPlane.Repo

  @scope_vps_create "vps_create"

  @doc "De scope voor het aanmaken van een VPS."
  def vps_create, do: @scope_vps_create

  @doc """
  Claimt `key` voor `user_id` binnen `scope`.

  Zie de moduledoc voor de drie uitkomsten.
  """
  # De kolom is 200 tekens. Een langere sleutel wordt GEWEIGERD en niet
  # afgekapt, en dat is geen strengheid maar noodzaak:
  #
  #   * Afkappen bij opslaan en zoeken op de volledige sleutel laat de opzoeker
  #     niets vinden. De code viel dan terug op "geen sleutel" en bestelde een
  #     tweede VPS met een tweede afschrijving -- precies wat deze module moet
  #     voorkomen.
  #   * Afkappen bij allebei is nog erger: twee verschillende lange sleutels
  #     worden na afkappen identiek, en dan krijgt een klant bij zijn tweede,
  #     écht andere bestelling de VPS van de eerste terug.
  #
  # Een sleutel die niet past is een fout van de client, en die hoort hij te
  # horen in plaats van er stilzwijgend iets anders van te maken.
  @max_key 200

  @spec claim(binary(), String.t() | nil, String.t()) ::
          {:ok, {:claimed, Key.t()} | {:done, binary()} | :zonder_sleutel}
          | {:error, :in_flight | :invalid_key}
  def claim(_user_id, nil, _scope), do: {:ok, :zonder_sleutel}
  def claim(_user_id, "", _scope), do: {:ok, :zonder_sleutel}

  def claim(user_id, key, scope) when is_binary(key) do
    if String.length(key) > @max_key do
      {:error, :invalid_key}
    else
      neem(user_id, key, scope)
    end
  end

  defp neem(user_id, key, scope) do
    %Key{}
    |> Key.changeset(%{user_id: user_id, key: key, scope: scope})
    |> Repo.insert()
    |> case do
      {:ok, rij} ->
        {:ok, {:claimed, rij}}

      {:error, _changeset} ->
        # De unieke index sloeg toe: er is al een verzoek met deze sleutel.
        bestaande(user_id, key, scope)
    end
  end

  defp bestaande(user_id, key, scope, opnieuw? \\ true) do
    case Repo.one(
           from k in Key,
             where: k.user_id == ^user_id and k.key == ^key and k.scope == ^scope
         ) do
      %Key{status: "done", vps_id: vps_id} when not is_nil(vps_id) ->
        {:ok, {:done, vps_id}}

      # Een sleutel die "bezig" zegt maar al lang niets meer doet, is van een
      # verzoek dat halverwege stierf: een uitrol, een crash. Alleen dat verzoek
      # kon hem vrijgeven, en dat leeft niet meer. Eerst bleef hij voorgoed
      # staan, en kreeg de klant op elke nieuwe poging "bestelling loopt al" --
      # tot hij de pagina herlaadde en een nieuwe sleutel kreeg. Nu mag dit
      # verzoek het overnemen. Eén keer: lukt de overname niet, dan was iemand
      # anders net eerder, en dan geldt diens rij.
      %Key{status: "in_flight"} = rij when opnieuw? ->
        neem_over_als_verlaten(rij, user_id, key, scope)

      %Key{status: "in_flight"} ->
        {:error, :in_flight}

      # "done" zonder VPS: die rij is weg (de verwijzing werd leeggemaakt). Er
      # valt niets terug te geven en niets af te wachten.
      %Key{} ->
        {:ok, :zonder_sleutel}

      # De rij is tussen de insert en deze query verdwenen. Dat kan echt
      # gebeuren: een gelijktijdig verzoek dat mislukte geeft zijn sleutel vrij
      # (`release/1`). Er is dan niets meer om op te wachten en dit verzoek mag
      # het werk doen.
      #
      # Let op bij het wijzigen: zolang de sleutel niet wordt verbouwd tussen
      # opslaan en opzoeken is dit een echte race en geen bug. Werd hij dat wel
      # -- afkappen bij het ene en niet bij het andere -- dan is deze tak de
      # plek waar een dubbele bestelling er stilletjes doorheen glipt.
      nil ->
        {:ok, :zonder_sleutel}
    end
  end

  # Een bestelling duurt seconden. Tien minuten zonder bijwerken is geen
  # langzaam verzoek meer maar een dood verzoek -- en ruim binnen de tijd
  # waarin de weessweep een afschrijving zonder VPS terugbetaalt, dus de klant
  # betaalt niet twee keer als hij opnieuw bestelt.
  @verlaten_na_seconden 600

  defp neem_over_als_verlaten(%Key{id: id, updated_at: bijgewerkt}, user_id, key, scope) do
    if verlaten?(bijgewerkt) and verwijder_verlaten(id) == 1,
      do: neem_opnieuw(user_id, key, scope),
      else: {:error, :in_flight}
  end

  defp verlaten?(bijgewerkt),
    do: DateTime.diff(DateTime.utc_now(), bijgewerkt, :second) >= @verlaten_na_seconden

  defp verwijder_verlaten(id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@verlaten_na_seconden, :second)

    {n, _} =
      Repo.delete_all(
        from k in Key, where: k.id == ^id and k.status == "in_flight" and k.updated_at <= ^cutoff
      )

    n
  end

  defp neem_opnieuw(user_id, key, scope) do
    %Key{}
    |> Key.changeset(%{user_id: user_id, key: key, scope: scope})
    |> Repo.insert()
    |> case do
      {:ok, rij} -> {:ok, {:claimed, rij}}
      {:error, _} -> bestaande(user_id, key, scope, false)
    end
  end

  @doc """
  Ruimt sleutels op die niemand meer nodig heeft.

  Een sleutel beschermt tegen een dubbel verzoek in de seconden of minuten
  rond een bestelling. Na een maand stuurt geen enkele client dezelfde sleutel
  nog, en zonder opruimen groeide de tabel met elke bestelling.
  """
  @spec ruim_op(pos_integer()) :: non_neg_integer()
  def ruim_op(dagen \\ 30) do
    cutoff = DateTime.add(DateTime.utc_now(), -dagen * 86_400, :second)
    {n, _} = Repo.delete_all(from k in Key, where: k.inserted_at < ^cutoff)
    n
  end

  @doc "Legt vast dat deze sleutel tot `vps_id` heeft geleid."
  @spec finish(Key.t(), binary()) :: :ok
  def finish(%Key{} = rij, vps_id) do
    rij |> Key.changeset(%{status: "done", vps_id: vps_id}) |> Repo.update()
    :ok
  end

  @doc """
  Geeft de sleutel weer vrij omdat het werk mislukte.

  Bewust vrijgeven en niet op "mislukt" zetten: de klant hoort het opnieuw te
  kunnen proberen, en met dezelfde sleutel. Een sleutel die na een mislukking
  blijft plakken zou een klant buitensluiten van zijn eigen bestelling.
  """
  @spec release(Key.t()) :: :ok
  def release(%Key{} = rij) do
    Repo.delete(rij)
    :ok
  end
end
