defmodule ControlPlane.Fleet.Regions do
  @moduledoc """
  De locaties waar nodes staan en waar een klant een VPS kan laten draaien.

  Een beheerder maakt regio's aan, hernoemt ze, zet ze aan of uit en
  verwijdert een lege locatie (`delete_region/1`). Een node-eigenaar kan een
  locatie op naam laten aanmaken met `ensure_region/1`, zodat hij niet hoeft te
  wachten tot een beheerder dat doet.

  Voor het bestellen geeft `available_regions/0` de locaties waar nu werkelijk
  iets geleverd kan worden, en kiest `auto_region_id/1` er een als de klant
  dat niet zelf deed.
  """
  import Ecto.Query

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.EnrollToken
  alias ControlPlane.Fleet.Liveness
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @doc """
  Returns all regions.
  """
  def list_regions do
    Repo.all(Region)
  end

  @doc """
  De locaties waar een node-eigenaar zijn machine heen kan zetten.

  Alle ingeschakelde regio's, ook de lege. Anders zou een nieuwe locatie nooit
  zijn eerste node kunnen krijgen -- en dat is precies hoe je een tweede
  datacenter in gebruik neemt.

  Een gesloten locatie hoort er ook bij zolang hij in `extra_ids` staat. Daar
  gaat het om de locaties waar de eigenaar zijn nodes al heeft staan: zou de
  huidige locatie ontbreken, dan wijst het keuzeveld in het dashboard een andere
  aan dan waar de machine werkelijk staat.
  """
  @spec selectable_regions([Ecto.UUID.t()]) :: [Region.t()]
  def selectable_regions(extra_ids \\ []) do
    ids = Enum.reject(extra_ids, &is_nil/1)

    Repo.all(from r in Region, where: r.enabled == true or r.id in ^ids, order_by: [asc: r.code])
  end

  @doc """
  Alle regio's met hoeveel nodes erin staan, voor het beheerscherm.

  Het aantal staat erbij omdat een regio zonder nodes niets kan leveren: die is
  te verwijderen of te vullen, en dat verschil hoort zichtbaar te zijn voordat
  iemand zich afvraagt waarom er niets in die locatie geplaatst wordt.
  """
  @spec list_regions_with_counts() :: [%{region: Region.t(), node_count: non_neg_integer()}]
  def list_regions_with_counts do
    counts =
      Repo.all(from n in Node, group_by: n.region_id, select: {n.region_id, count(n.id)})
      |> Map.new()

    from(r in Region, order_by: [asc: r.code])
    |> Repo.all()
    |> Enum.map(&%{region: &1, node_count: Map.get(counts, &1.id, 0)})
  end

  @doc """
  Wijzigt de naam of de code van een regio, of zet hem aan of uit.

  De code mag mee. Nodes en VPS'en verwijzen naar de regio op id, dus er breekt
  geen enkele koppeling -- wat breekt is een script van een operator waar de
  oude code met de hand in staat. Dat is een keuze van een beheerder en geen
  gevolg dat hij moet ontdekken, dus het scherm zegt het erbij.
  """
  @spec update_region(Ecto.UUID.t(), map()) ::
          {:ok, Region.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_region(region_id, attrs) do
    case Repo.get(Region, region_id) do
      nil ->
        {:error, :not_found}

      region ->
        region
        |> Region.changeset(Map.take(attrs, ~w(name code enabled) ++ [:name, :code, :enabled]))
        |> Repo.update()
    end
  end

  @doc """
  Verwijdert een locatie die niets meer bevat.

  "Niets meer" betekent: geen node, geen draaiende VPS, en geen openstaande
  uitnodiging. Een VPS die allang verwijderd is houdt niets tegen -- die laat
  zijn locatie los zodra de locatie wordt opgeruimd. Wat daarmee verdwijnt is
  het label "deze verwijderde machine draaide in Landhorst"; alles waar de
  administratie aan hangt (grootboek, abonnement, verbruik) verwijst naar de VPS
  en niet naar de regio.

  Dat was eerst anders: `vpses.region_id` was verplicht met `restrict`, en
  daarmee was een locatie waar ooit iets in had gedraaid nooit meer weg te
  gooien. In de praktijk is dat elke locatie die ooit gebruikt is, dus bleef een
  typefout voor altijd in het beheerscherm staan.

  De reden waarom het niet kan komt terug als aparte fout, want ze vragen om
  iets anders van degene die het probeert: nodes kun je verplaatsen, een
  openstaande uitnodiging kun je intrekken, en aan een VPS-geschiedenis valt
  niets te doen. "Verwijderen mislukt" zou hem laten raden.

  Uitzetten blijft het alternatief voor een locatie die wordt afgebouwd: zie
  `update_region/2`. Dan blijft draaien wat draait en komt er niets nieuws bij.
  """
  @spec delete_region(Ecto.UUID.t()) ::
          :ok | {:error, :not_found | :has_nodes | :has_vpses | :has_enroll_tokens}
  def delete_region(region_id) do
    case Repo.get(Region, region_id) do
      nil ->
        {:error, :not_found}

      region ->
        # Eerst zelf tellen, want dat geeft een bruikbaar antwoord. De
        # constraints hieronder zijn het vangnet voor wat er tussen tellen en
        # verwijderen bij komt.
        cond do
          telt?(Node, region.id) -> {:error, :has_nodes}
          draaiende_vps?(region.id) -> {:error, :has_vpses}
          open_uitnodiging?(region.id) -> {:error, :has_enroll_tokens}
          true -> verwijder_regio(region)
        end
    end
  end

  defp telt?(schema, region_id) do
    Repo.exists?(from r in schema, where: r.region_id == ^region_id)
  end

  # Alleen een VPS die er nog is houdt een locatie tegen. Een verwijderde VPS
  # laat zijn locatie los zodra de locatie wordt opgeruimd (`ON DELETE SET
  # NULL`): wat daarmee verdwijnt is het label "deze verwijderde machine draaide
  # in Landhorst", en alles waar de administratie aan hangt verwijst naar de VPS
  # en niet naar de regio.
  defp draaiende_vps?(region_id) do
    Repo.exists?(from v in Vps, where: v.region_id == ^region_id and v.status != :deleted)
  end

  # Alleen een uitnodiging die iemand nog kan gebruiken telt: ongebruikt én niet
  # verlopen. Een token dat al is ingewisseld of allang is verlopen blijft als
  # rij staan, en die rijen hielden een locatie tegen met de melding "er staat
  # nog een uitnodiging open" -- terwijl er niets openstond en er in het scherm
  # ook niets te zien was. Een melding die niet klopt met wat iemand ziet is
  # erger dan geen melding.
  defp open_uitnodiging?(region_id) do
    nu = Clock.now()

    Repo.exists?(
      from t in EnrollToken,
        where: t.region_id == ^region_id and is_nil(t.used_at) and t.expires_at > ^nu
    )
  end

  defp verwijder_regio(%Region{} = region) do
    # In één transactie: de dode uitnodigingen eruit en dan de locatie zelf.
    # Apart zou betekenen dat een mislukte verwijdering de tokens al heeft
    # weggegooid van een locatie die blijft bestaan.
    Repo.transaction(fn ->
      # Uitnodigingen die niemand meer kan gebruiken gaan mee. Ze verwijzen naar
      # een locatie die zo meteen niet meer bestaat, en een ingewisseld of
      # verlopen token heeft geen waarde meer -- het is eenmalig en tijdgebonden.
      Repo.delete_all(from t in EnrollToken, where: t.region_id == ^region.id)

      case verwijder_rij(region) do
        :ok -> :ok
        {:error, reden} -> Repo.rollback(reden)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reden} -> {:error, reden}
    end
  end

  defp verwijder_rij(%Region{} = region) do
    region
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :nodes_region_id_fkey,
      message: "has_nodes"
    )
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :vpses_region_id_fkey,
      message: "has_vpses"
    )
    |> Ecto.Changeset.foreign_key_constraint(:id,
      name: :enroll_tokens_region_id_fkey,
      message: "has_enroll_tokens"
    )
    |> Repo.delete()
    |> case do
      {:ok, _} ->
        :ok

      {:error, %Ecto.Changeset{errors: errors}} ->
        {:error, reden_uit_errors(errors)}
    end
  end

  defp reden_uit_errors(errors) do
    case Keyword.get(errors, :id) do
      {"has_nodes", _} -> :has_nodes
      {"has_vpses", _} -> :has_vpses
      {"has_enroll_tokens", _} -> :has_enroll_tokens
      _ -> :has_vpses
    end
  end

  @doc """
  Fetches a single region by id, raising `Ecto.NoResultsError` if none exists.
  """
  def get_region!(id), do: Repo.get!(Region, id)

  @doc """
  Fetches a single region by its unique `code` (e.g. "nl-1").

  Returns the `%Region{}` or `nil` if no region has that code.
  """
  def region_by_code(code) when is_binary(code) do
    Repo.get_by(Region, code: code)
  end

  @doc """
  Creates a region from the given attributes.
  """
  def create_region(attrs) do
    %Region{}
    |> Region.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  De locatie met deze naam, aangemaakt als hij nog niet bestaat.

  Bestaat hij al -- op naam of op code, hoofdletters maken niet uit -- dan wordt
  díé teruggegeven. Twee rijen "Eindhoven" zouden dezelfde plek zijn met een
  ander id, en dan splitst de capaciteit van één datacenter zich over twee
  keuzes in het bestelscherm.
  """
  @spec ensure_region(String.t()) ::
          {:ok, Region.t()} | {:error, :invalid_region | Ecto.Changeset.t()}
  def ensure_region(naam) when is_binary(naam) do
    schoon = naam |> String.trim() |> String.replace(~r/\s+/u, " ")

    cond do
      String.length(schoon) < 2 -> {:error, :invalid_region}
      String.length(schoon) > 60 -> {:error, :invalid_region}
      not plaatsnaam?(schoon) -> {:error, :invalid_region}
      true -> bestaande_regio(schoon) || nieuwe_regio(schoon)
    end
  end

  def ensure_region(_), do: {:error, :invalid_region}

  # Een regionaam komt van de eigenaar van een node en wordt getoond aan klanten
  # die een VPS bestellen -- "waar moet hij draaien". Dat is door een
  # semi-vertrouwde partij bepaalde tekst op een plek waar een vreemde hem leest.
  #
  # De schermen escapen hun invoer, dus dit is geen XSS-gat; het gaat erom dat
  # een plaatsnaam een plaatsnaam is. Letters (met accenten), cijfers, spatie,
  # koppelteken, apostrof en punt dekken alles wat een echte plaats heet --
  # 's-Hertogenbosch, Den Haag, Saint-Denis -- en laten markup, adressen, emoji
  # en stuurtekens buiten.
  defp plaatsnaam?(naam), do: Regex.match?(~r/^[[:alpha:]0-9 .'\-]+$/u, naam)

  defp bestaande_regio(naam) do
    gezocht = String.downcase(naam)

    query =
      from r in Region,
        where: fragment("lower(?)", r.name) == ^gezocht or r.code == ^gezocht,
        order_by: [asc: r.inserted_at],
        limit: 1

    case Repo.one(query) do
      nil -> nil
      region -> {:ok, region}
    end
  end

  defp nieuwe_regio(naam) do
    %Region{}
    |> Region.changeset(%{code: vrije_code(naam), name: naam})
    |> Repo.insert()
    |> case do
      {:ok, region} -> {:ok, region}
      # Twee eigenaren die tegelijk dezelfde plaats intypen: de tweede vindt hem
      # nu gewoon, in plaats van een foutmelding te krijgen over een code die hij
      # nooit zelf heeft gekozen.
      {:error, changeset} -> bestaande_regio(naam) || {:error, changeset}
    end
  end

  # De code wordt van de naam afgeleid. Hij moet kort en blijvend zijn, dus geen
  # accenten, spaties of hoofdletters -- en bij een botsing een nummer erachter,
  # want twee verschillende plaatsen kunnen tot dezelfde code leiden.
  defp vrije_code(naam) do
    basis =
      naam
      |> String.downcase()
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/[\x{0300}-\x{036f}]/u, "")
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 24)

    basis = if basis == "", do: "regio", else: basis

    Enum.find_value(1..50, "#{basis}-#{System.unique_integer([:positive])}", fn n ->
      kandidaat = if n == 1, do: basis, else: "#{basis}-#{n}"
      if Repo.exists?(from r in Region, where: r.code == ^kandidaat), do: nil, else: kandidaat
    end)
  end

  @doc """
  The region to place `request` in when the customer did not pick one.

  Picks the region of the node that would be left with the most headroom — the
  same measure the scheduler uses to choose between nodes, applied one level up,
  so "automatic" lands on the emptiest machine in the fleet rather than on
  whichever region happens to sort first.

  Advisory only: nothing is locked here. The scheduler still makes the real
  decision inside its transaction, and may pick a different node in the region if
  this one filled up in between.
  """
  def auto_region_id(%{vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb} = request) do
    Liveness.online_nodes_in_region_query(nil)
    |> where(
      [n],
      n.available_vcpu >= ^vcpu and n.available_ram_mb >= ^ram_mb and
        n.available_disk_gb >= ^disk_gb
    )
    |> Repo.all()
    |> case do
      [] ->
        {:error, :no_capacity}

      nodes ->
        # Een uitgeschakelde regio is geen kandidaat: automatisch plaatsen mag
        # niet uitkomen op een locatie die bewust is gesloten.
        actief =
          Repo.all(from r in Region, where: r.enabled == true, select: r.id) |> MapSet.new()

        case Enum.filter(nodes, &MapSet.member?(actief, &1.region_id)) do
          [] ->
            {:error, :no_capacity}

          kandidaten ->
            {:ok, Enum.max_by(kandidaten, &Node.headroom_score(&1, request)).region_id}
        end
    end
  end

  @doc """
  Regions a customer can currently be placed in: those with at least one online
  node reporting free capacity.

  A region with no node behind it is not a choice, it is a disappointment —
  listing it would let someone pick a location we cannot actually deliver.
  """
  def available_regions do
    node_ids =
      Liveness.online_nodes_in_region_query(nil)
      |> where([n], n.available_vcpu > 0 and n.available_ram_mb > 0 and n.available_disk_gb > 0)
      |> select([n], n.region_id)

    # `enabled` hoort hier thuis en niet alleen in het beheerscherm: een regio die
    # wordt afgebouwd moet stoppen met nieuwe VPS'en aannemen terwijl wat er
    # draait blijft draaien -- hetzelfde idee als een node die draint.
    from(r in Region,
      where: r.id in subquery(node_ids) and r.enabled == true,
      order_by: [asc: r.code]
    )
    |> Repo.all()
  end
end
