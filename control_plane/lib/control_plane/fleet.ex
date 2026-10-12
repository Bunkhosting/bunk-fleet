defmodule ControlPlane.Fleet do
  @moduledoc """
  The Fleet context: regions, nodes, VPSes and capacity reservations that make up
  the federated VPS control plane.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Accounts.User
  alias ControlPlane.Clock
  alias ControlPlane.Fleet.EnrollToken
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Housekeeping
  alias ControlPlane.Fleet.Liveness
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
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
  Returns all nodes, with their region preloaded, newest first.
  """
  def list_nodes(opts \\ []) do
    Repo.all(
      from n in Node,
        order_by: [desc: n.inserted_at],
        limit: ^Keyword.get(opts, :limit, 500),
        preload: [:region, :owner]
    )
  end

  @doc """
  Closes a node to new VPSes without taking anything away from the ones on it.

  This is what you do before maintenance, before removing a node, or when a
  machine is misbehaving: the scheduler stops placing there (it only considers
  `:online` nodes), while the node keeps heartbeating, keeps serving its existing
  customers, and keeps accepting start/stop/delete/console work for them.

  Emptying it afterwards is deliberate and manual — moving a customer's VPS is not
  something to trigger by changing a status field.
  """
  def drain_node(node_id, reason \\ nil) do
    set_node_status(node_id, :draining, [:online, :offline, :pending], reason)
  end

  @doc "De nodes die `user` beheert, nieuwste eerst."
  @spec list_nodes_owned_by(User.t()) :: [Node.t()]
  def list_nodes_owned_by(%User{id: id}) do
    Repo.all(
      from n in Node,
        where: n.owner_id == ^id,
        order_by: [desc: n.inserted_at],
        preload: [:region]
    )
  end

  @doc """
  Verplaatst een node naar een andere regio, mits `user` de eigenaar is.

  De VPS'en erop gaan mee. Een regio beschrijft waar de machine fysiek staat, en
  een VPS kan niet ergens anders staan dan de machine waarop hij draait — laat je
  ze achter in de oude regio, dan liegt het label bij elke klant die het opvraagt.

  De eigenaar bepaalt dit en niet een beheerder: alleen hij weet waar zijn
  hardware daadwerkelijk staat.
  """
  @spec move_node_to_region(Ecto.UUID.t(), User.t(), Ecto.UUID.t()) ::
          {:ok, Node.t()}
          | {:error, :not_found | :forbidden | :unknown_region | Ecto.Changeset.t()}
  def move_node_to_region(node_id, %User{} = user, region_id) do
    with {:ok, node} <- fetch_node(node_id),
         true <- node_owner?(node, user) or {:error, :forbidden},
         :ok <- known_region(region_id) do
      Repo.transaction(fn -> verhuis(node, region_id) end)
      |> tap_ok(fn _ -> Events.broadcast_changed(:node) end)
      |> met_regio()
    else
      {:error, reden} -> {:error, reden}
    end
  end

  @doc """
  Verplaatst de node naar de locatie met deze naam, en maakt die aan als hij nog
  niet bestaat.

  Een node-eigenaar hoeft niet te wachten tot een beheerder zijn plaats heeft
  aangemaakt: hij typt waar de machine staat. De eigenaarscontrole gaat er
  bewust vóór -- zou hij erna komen, dan kon een vreemde met een willekeurig
  node-id locaties aanmaken die hij nooit mag gebruiken en die wel in het
  beheerscherm verschijnen.
  """
  @spec move_node_to_named_region(Ecto.UUID.t(), User.t(), String.t()) ::
          {:ok, Node.t()}
          | {:error, :not_found | :forbidden | :invalid_region | Ecto.Changeset.t()}
  def move_node_to_named_region(node_id, %User{} = user, naam) do
    with {:ok, node} <- fetch_node(node_id),
         true <- node_owner?(node, user) or {:error, :forbidden},
         {:ok, region} <- ensure_region(naam) do
      move_node_to_region(node.id, user, region.id)
    else
      {:error, reden} -> {:error, reden}
    end
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

  # De regio erbij, zodat wie de node terugkrijgt meteen ziet waar hij staat --
  # ook als die locatie zojuist is aangemaakt en dus in geen enkele lijst stond
  # die de browser al had.
  defp met_regio({:ok, node}), do: {:ok, Repo.preload(node, :region)}
  defp met_regio(anders), do: anders

  # Een verwijderde VPS draait nergens meer en houdt de regio waar hij ooit
  # stond; zijn geschiedenis hoort te blijven kloppen.
  defp verhuis(node, region_id) do
    from(v in Vps, where: v.node_id == ^node.id and v.status != :deleted)
    |> Repo.update_all(set: [region_id: region_id])

    case node |> Node.changeset(%{region_id: region_id}) |> Repo.update() do
      {:ok, bijgewerkt} -> bijgewerkt
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp known_region(region_id) do
    if Repo.exists?(from r in Region, where: r.id == ^region_id),
      do: :ok,
      else: {:error, :unknown_region}
  end

  @doc """
  Wijzigt de instellingen van een node, mits `user` de eigenaar is.

  De eigenaarscontrole zit hier en niet alleen in de controller: een tweede
  ingang naar deze functie mag niet per ongeluk om het slot heen komen.
  """
  @spec update_node_settings(Ecto.UUID.t(), User.t(), map()) ::
          {:ok, Node.t()} | {:error, :not_found | :forbidden | Ecto.Changeset.t()}
  def update_node_settings(node_id, %User{} = user, attrs) do
    with {:ok, node} <- fetch_node(node_id),
         true <- node_owner?(node, user) or {:error, :forbidden} do
      node
      |> Node.settings_changeset(attrs, package_template_ids())
      |> Repo.update()
      |> tap_ok(fn _ -> Events.broadcast_changed(:node) end)
      |> met_regio()
    else
      {:error, reden} -> {:error, reden}
    end
  end

  @doc """
  Draagt een node over, of wijst er voor het eerst een eigenaar aan.

  Wie mag dat: de eigenaar zelf, en verder niemand. Een beheerder kan een node
  die nog géén eigenaar heeft toewijzen -- anders zou een node die met een
  beheerderstoken is ingeschreven er nooit een kunnen krijgen -- maar zodra er
  een eigenaar is, is die de enige die hem kan overdragen.

  Dat heeft een scherpe kant en die hoort hier te staan: raakt een eigenaar
  onbereikbaar, dan kan niemand die node nog overdragen. Het alternatief was een
  noodluik voor beheerders, en dat is precies wat "alleen de eigenaar" niet
  betekent.
  """
  @spec assign_node_owner(Ecto.UUID.t(), User.t(), Ecto.UUID.t() | nil) ::
          {:ok, Node.t()}
          | {:error, :not_found | :forbidden | :unknown_user | Ecto.Changeset.t()}
  def assign_node_owner(node_id, %User{} = door, owner_id) do
    with {:ok, node} <- fetch_node(node_id),
         :ok <- mag_overdragen(node, door),
         :ok <- known_user(owner_id) do
      node
      |> Node.changeset(%{owner_id: owner_id})
      |> Repo.update()
      |> tap_ok(fn _ -> Events.broadcast_changed(:node) end)
      |> met_regio()
    end
  end

  # Een node zonder eigenaar mag een beheerder toewijzen; dat is het enige
  # moment waarop iemand anders dan de eigenaar erover gaat.
  defp mag_overdragen(%Node{owner_id: nil}, %User{role: :admin}), do: :ok
  defp mag_overdragen(%Node{owner_id: nil}, _user), do: {:error, :forbidden}

  defp mag_overdragen(%Node{} = node, %User{} = user) do
    if node_owner?(node, user), do: :ok, else: {:error, :forbidden}
  end

  # De templates waarmee besteld kan worden. Los opgehaald zodat het changeset
  # zelf niets van de database hoeft te weten.
  defp package_template_ids do
    Repo.all(
      from p in Package, where: not is_nil(p.template_id), select: p.template_id, distinct: true
    )
  end

  defp fetch_node(node_id) do
    case Repo.get(Node, node_id) do
      nil -> {:error, :not_found}
      node -> {:ok, node}
    end
  end

  defp known_user(nil), do: :ok

  defp known_user(owner_id) do
    if Repo.exists?(from u in User, where: u.id == ^owner_id),
      do: :ok,
      else: {:error, :unknown_user}
  end

  @doc """
  Of `user` de instellingen van `node` mag wijzigen.

  Alleen de eigenaar. Een beheerder die eraan moet zijn, draagt de node eerst aan
  zichzelf over — dat laat een spoor na, en een noodluik dat niemand ziet is geen
  noodluik.
  """
  @spec node_owner?(Node.t(), User.t() | nil) :: boolean()
  def node_owner?(%Node{owner_id: owner_id}, %User{id: id}) when not is_nil(owner_id),
    do: owner_id == id

  def node_owner?(_node, _user), do: false

  @doc """
  Reopens a drained node to new VPSes.

  Goes back to `:online` rather than to whatever it was: a node that is being
  reopened is one someone has just looked at, and its next heartbeat — thirty
  seconds away at most — settles the question either way.
  """
  def resume_node(node_id) do
    # De reden verdwijnt bij het heropenen: iemand heeft ernaar gekeken en
    # besloten dat het weer mag. Hem laten staan zou de volgende lezer vertellen
    # dat er nog iets mis is.
    set_node_status(node_id, :online, [:draining], nil)
  end

  defp set_node_status(node_id, status, from, reason) do
    case Repo.get(Node, node_id) do
      nil ->
        {:error, :not_found}

      %Node{status: current} = node when current != status ->
        if current in from,
          do: transition_node(node, status, reason),
          else: {:error, {:invalid_status, current}}

      %Node{} = node ->
        # Already there. Draining a draining node is not an error; it is the
        # state the caller asked for. De reden wordt wel bijgewerkt: een tweede
        # mislukking met een andere oorzaak is nieuwere informatie dan de eerste.
        transition_node(node, status, reason)
    end
  end

  defp transition_node(node, status, reason) do
    node
    |> Node.mark_online_changeset(%{status: status, drain_reason: reason})
    |> Repo.update()
    |> tap_ok(fn _ -> Events.broadcast_changed(:node) end)
  end

  @doc """
  Removes a node from the fleet.

  Refuses with `{:error, :node_has_vpses}` while the node still hosts any live
  (non-`:deleted`/`:failed`) VPS, so removing a node can never orphan a running
  customer VM — those must be torn down first. On success the node's commands and
  reservations cascade-delete and any dead VPSes' `node_id` is nilified. Returns
  `{:error, :not_found}` for an unknown id.

  Note: the node's agent (if still running) keeps its persisted credentials, so
  its next heartbeat will 401 against the now-missing node — stop/uninstall the
  agent on that machine after removal.
  """
  def delete_node(node_id) do
    case Repo.get(Node, node_id) do
      nil ->
        {:error, :not_found}

      %Node{} = node ->
        live =
          Repo.aggregate(
            from(v in Vps, where: v.node_id == ^node_id and v.status not in [:deleted, :failed]),
            :count
          )

        if live > 0 do
          {:error, :node_has_vpses}
        else
          Repo.delete(node)
        end
    end
  end

  @doc """
  Returns all VPSes, with their region preloaded, newest first.
  """
  @spec list_vpses(keyword()) :: [Vps.t()]
  def list_vpses(opts \\ []) do
    Repo.all(
      from v in Vps,
        order_by: [desc: v.inserted_at],
        limit: ^Keyword.get(opts, :limit, 500),
        preload: [:region]
    )
  end

  @doc "Available VPS packages, ordered like the catalog (sort_order, price)."
  def list_available_packages do
    Repo.all(
      from p in Package,
        where: p.is_available == true,
        order_by: [asc: p.sort_order, asc: p.price_monthly]
    )
  end

  def get_package(id), do: Repo.get(Package, id)

  @doc """
  The available package whose specs exactly match `vcpu`/`ram_mb`/`disk_gb`, or
  `nil`. Lets a self-service VPS be priced from the catalogue server-side rather
  than trusting any client-supplied price — an unmatched spec is simply rejected.
  """
  def package_for_specs(vcpu, ram_mb, disk_gb) do
    with v when is_integer(v) <- coerce_int(vcpu),
         m when is_integer(m) <- coerce_int(ram_mb),
         d when is_integer(d) <- coerce_int(disk_gb),
         # RAM must be an exact whole-GB match. Without this, ram_mb=3000 rounds
         # via div(m,1024)=2 to the 2 GB package's price while ~3 GB is actually
         # provisioned — underpay + silent oversell of real node capacity.
         true <- rem(m, 1024) == 0 do
      Repo.one(
        from p in Package,
          where:
            p.is_available == true and p.cpu_cores == ^v and
              p.ram_gb == ^div(m, 1024) and p.disk_gb == ^d,
          limit: 1
      )
    else
      _ -> nil
    end
  end

  defp coerce_int(v) when is_integer(v), do: v

  defp coerce_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp coerce_int(_), do: nil

  @doc """
  Returns the VPSes owned by `owner_id`, region preloaded, newest first.
  """
  @spec list_vpses_for_owner(binary()) :: [Vps.t()]
  def list_vpses_for_owner(owner_id) do
    # Exclude :deleted — a torn-down VPS must vanish from the customer's list
    # (the frontend renders whatever this returns), not linger as a ghost row.
    Repo.all(
      from v in Vps,
        where: v.owner_id == ^owner_id and v.status != :deleted,
        order_by: [desc: v.inserted_at],
        # :node and :port_forwards are what turn an unroutable 10.x address into
        # the endpoint a customer can actually type into ssh. :package draagt de
        # prijs die het paneel toont; die hoort bij de machine en niet bij een
        # catalogus die de browser toevallig nog in het geheugen heeft.
        preload: [:region, :node, :port_forwards, :package]
    )
  end

  @doc """
  Fetches a single VPS by `id`, but only if it is owned by `owner_id`.

  Returns `nil` when the VPS does not exist *or* belongs to another owner — the
  caller cannot distinguish the two, so this doubles as the authorization check.
  """
  @spec get_vps_for_owner(binary(), binary()) :: Vps.t() | nil
  def get_vps_for_owner(owner_id, id) do
    Repo.one(
      from v in Vps,
        where: v.id == ^id and v.owner_id == ^owner_id,
        preload: [:region, :node, :port_forwards, :package]
    )
  end

  @doc """
  Hernoemt een VPS.

  Alleen het label dat de klant ziet. De naam waaronder de gast op de
  hypervisor staat verandert niet: daar herkent de agent zijn machine aan, en
  die naam is bij het uitrollen vastgelegd. Zou hij meeveranderen, dan raakte de
  agent zijn eigen VM kwijt -- of erger, vond hij die van iemand anders.

  Een verwijderde VPS wordt niet hernoemd. Die draait nergens meer; zijn naam
  staat nog in verbruiksregels en facturen, en die horen te blijven zeggen wat
  ze toen zeiden.
  """
  @spec rename_vps(Vps.t(), String.t()) ::
          {:ok, Vps.t()} | {:error, :invalid_status | Ecto.Changeset.t()}
  def rename_vps(%Vps{status: :deleted}, _naam), do: {:error, :invalid_status}

  def rename_vps(%Vps{} = vps, naam) when is_binary(naam) do
    vps
    |> Vps.changeset(%{name: String.trim(naam)})
    |> Repo.update()
    |> tap_ok(fn _ -> Events.broadcast_changed(:vps) end)
  end

  def rename_vps(%Vps{}, _naam), do: {:error, :invalid_status}

  @doc "Zie `ControlPlane.Fleet.Liveness.register_node/1`."
  defdelegate register_node(attrs), to: Liveness

  @doc "Zie `ControlPlane.Fleet.Liveness.mark_online_heartbeat/2`."
  defdelegate mark_online_heartbeat(node, total_attrs), to: Liveness

  # Runs `fun` only when `result` is `{:ok, value}`, then returns `result`
  # unchanged. Used to fire a best-effort PubSub event as a side-effect after a
  # successful DB write without altering the function's return value.
  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result

  @doc "Zie `ControlPlane.Fleet.Liveness.online_nodes_in_region_query/1`."
  defdelegate online_nodes_in_region_query(region_id), to: Liveness

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

  @doc false
  defdelegate heartbeat_ttl_seconds(), to: Liveness

  @doc "Zie `ControlPlane.Fleet.Housekeeping.scrub_deleted_vpses/1`."
  defdelegate scrub_deleted_vpses(dagen \\ 30), to: Housekeeping

  @doc "Zie `ControlPlane.Fleet.Liveness.mark_stale_nodes_offline/0`."
  defdelegate mark_stale_nodes_offline(), to: Liveness

  @doc "Zie `ControlPlane.Fleet.Liveness.mark_stale_nodes_offline/1`."
  defdelegate mark_stale_nodes_offline(cutoff), to: Liveness

  @doc "Zie `ControlPlane.Fleet.Housekeeping.release_orphaned_reservations/0`."
  defdelegate release_orphaned_reservations(), to: Housekeeping
end
