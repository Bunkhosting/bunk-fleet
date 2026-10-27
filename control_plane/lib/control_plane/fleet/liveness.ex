defmodule ControlPlane.Fleet.Liveness do
  @moduledoc """
  Of een node leeft, en wat hij zegt te kunnen dragen.

  Een node schrijft zich in met `register_node/1` en meldt zich daarna steeds
  opnieuw met een hartslag, die `mark_online_heartbeat/2` verwerkt: de node gaat
  (weer) op `:online`, zijn gemelde totalen worden bijgewerkt en de vrije ruimte
  die de scheduler mag vergeven wordt afgeleid uit wat de agent vrij ziet minus
  wat er al gereserveerd is.

  Blijft de hartslag langer weg dan `heartbeat_ttl_seconds/0`, dan telt de node
  niet meer mee voor plaatsing (`online_nodes_in_region_query/1`) en zet
  `mark_stale_nodes_offline/0` hem ook in de database op `:offline`.
  """
  import Ecto.Query

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Repo

  # A node is considered "online" for scheduling purposes only if it has reported
  # a heartbeat within this window.
  @heartbeat_ttl_seconds 120

  @doc """
  Registers (enrolls) a new node in the fleet.

  On enrollment the node's live `available_*` capacity is initialised to its
  advertised `total_*` (unless explicitly provided), since a fresh node hosts no
  VPSes yet. From then on `available_*` is owned solely by the scheduler.
  """
  def register_node(attrs) do
    %Node{}
    |> Node.changeset(default_available(normalize_keys(attrs)))
    |> Repo.insert()
  end

  defp default_available(attrs) do
    attrs
    |> Map.put_new(:available_vcpu, attrs[:total_vcpu])
    |> Map.put_new(:available_ram_mb, attrs[:total_ram_mb])
    |> Map.put_new(:available_disk_gb, attrs[:total_disk_gb])
  end

  @doc """
  Applies an authenticated heartbeat from a node: refreshes its advertised `total_*`
  capacity and `last_heartbeat_at`, and (re)asserts the node as `:online`.

  The `:online` status transition is trusted server-side logic (the node's agent
  token has already been authenticated), so it is applied here via
  `Node.mark_online_changeset/2` rather than the agent-driven
  `Node.heartbeat_changeset/2`. As with all heartbeats, `available_*` is never
  touched — that remains owned solely by the scheduler.

  `total_attrs` may use either atom or string keys and is expected to carry
  `total_vcpu` / `total_ram_mb` / `total_disk_gb`.
  """
  def mark_online_heartbeat(%Node{} = node, total_attrs) do
    totals =
      total_attrs
      |> normalize_keys()
      |> Map.take([
        :total_vcpu,
        :total_ram_mb,
        :total_disk_gb,
        :agent_version,
        :capacity_error,
        :network_note,
        :reported_avail_vcpu,
        :reported_avail_ram_mb,
        :reported_avail_disk_gb
      ])
      |> without_capacity_when_unknown()
      # Een heartbeat zonder notitie wist een eerdere. De agent laat het veld weg
      # als er niets te melden valt, dus afwezig betekent "het is rechtgezet" --
      # anders bleef een notitie voor een probleem dat al weg is tot in
      # eeuwigheid in het paneel staan.
      |> Map.put_new(:network_note, nil)

    # Een hartslag betekent dat de uitval voorbij is, dus de volgende begint met
    # een schone lei. Dit zit hier en niet in de agent-gevulde `totals`: de agent
    # mag niet bepalen of er gemeld wordt.
    basis =
      totals
      |> Map.put(:last_heartbeat_at, Clock.now())
      |> Map.put(:offline_notified_at, nil)

    # PERF: only a real status transition (offline/pending -> online) or the
    # first heartbeat (which seeds available_*) is UI-relevant. A routine
    # heartbeat just refreshes last_heartbeat_at/total_*, so it must NOT broadcast
    # — otherwise every node's heartbeat forces every connected dashboard to a
    # full reload (O(nodes x dashboards) per interval). Capacity changes are
    # broadcast by the scheduler, and offline transitions by the reconciler.
    # In één transactie, met de node onder slot. De afgeleide vrije ruimte wordt
    # gelezen (de lopende reserveringen) en daarna geschreven; zonder slot kan een
    # plaatsing daar precies tussen committen en wordt haar afboeking overschreven
    # -- de zojuist gereserveerde ruimte staat dan weer als vrij te boek en kan
    # een tweede keer verkocht worden. De scheduler vergrendelt dezelfde rij, dus
    # de twee serialiseren nu in plaats van elkaar te overschrijven.
    Repo.transaction(fn ->
      vers = Repo.one!(from n in Node, where: n.id == ^node.id, lock: "FOR UPDATE")

      # De status wordt uit de verse rij bepaald, niet uit de node waarmee dit
      # verzoek binnenkwam. Die is geladen voordat het slot er was, en tussen die
      # twee momenten kan een beheerder de node hebben afgesloten -- of kan een
      # mislukte bestelling hem automatisch hebben dichtgezet. Met de oude waarde
      # zou deze heartbeat dat overschrijven en gaat een node die je juist leeg
      # wilt hebben weer vollopen.
      #
      # Een node die draint is nog steeds in leven en bedient wat hij heeft; hij
      # is alleen dicht voor nieuwe VPS'en.
      status = if vers.status == :draining, do: :draining, else: :online
      attrs = basis |> Map.put(:status, status) |> derive_available(vers, totals)

      transition? =
        vers.status not in [:online, :draining] or is_nil(vers.available_vcpu) or
          capacity_changed?(vers, attrs)

      vers
      |> Node.mark_online_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, bijgewerkt} -> {bijgewerkt, transition?}
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      # Het uitzenden gebeurt na de commit: een abonnee die meteen terugleest
      # moet de nieuwe stand zien, niet de stand van binnen de transactie.
      {:ok, {bijgewerkt, true}} ->
        Events.broadcast_changed(:node)
        {:ok, bijgewerkt}

      {:ok, {bijgewerkt, false}} ->
        {:ok, bijgewerkt}

      {:error, reden} ->
        {:error, reden}
    end
  end

  # Een heartbeat met een capacity_error komt van een agent die leeft maar zijn
  # hypervisor niet kan bevragen. De getallen die daarbij zitten zijn nullen en
  # geen meting, dus de laatst bekende totalen blijven staan -- die zeggen nog
  # steeds wat deze machine is. Wat de agent vrij ziet gaat wel op nul: zolang
  # hij niet kan kijken, mag de scheduler er niets op zetten.
  defp without_capacity_when_unknown(%{capacity_error: reden} = totals)
       when is_binary(reden) and reden != "" do
    totals
    |> Map.drop([:total_vcpu, :total_ram_mb, :total_disk_gb])
    |> Map.merge(%{
      reported_avail_vcpu: 0,
      reported_avail_ram_mb: 0,
      reported_avail_disk_gb: 0
    })
  end

  defp without_capacity_when_unknown(totals), do: Map.put_new(totals, :capacity_error, nil)

  defp capacity_changed?(%Node{} = node, attrs) do
    Enum.any?([:available_vcpu, :available_ram_mb, :available_disk_gb], fn veld ->
      Map.has_key?(attrs, veld) and Map.fetch!(attrs, veld) != Map.fetch!(node, veld)
    end)
  end

  # Wat de scheduler nog mag vergeven, afgeleid in plaats van geraden.
  #
  # Tot nu toe werd available_* bij de eerste heartbeat eenmalig gelijkgesteld aan
  # het totaal van de machine, en daarna alleen nog verlaagd bij een reservering.
  # Dat startpunt gaat ervan uit dat de hele machine van Bunk is. Draait er ook
  # iets anders op -- het control plane zelf, een router, een website -- dan is
  # het vanaf de eerste seconde een fictie, en omdat het maar één keer gebeurt
  # corrigeert geen enkele heartbeat het ooit nog. Op de eerste node van deze
  # vloot scheelde dat 7 GB: 10819 MB "vrij" terwijl er 3651 MB vrij was.
  #
  # Wat er werkelijk te vergeven is, is wat de node vrij ziet minus wat er al is
  # beloofd aan VPS'en die nog gemaakt worden. Die draaien nog niet, dus de agent
  # telt hun geheugen nog als vrij; zonder die aftrek zou dezelfde ruimte twee
  # keer verkocht kunnen worden. Zo afgeleid klopt het cijfer in beide richtingen
  # en herstelt het zich vanzelf.
  defp derive_available(attrs, %Node{} = node, totals) do
    case reported_capacity(totals) do
      nil -> maybe_init_available(attrs, node, totals)
      reported -> Map.merge(attrs, minus_held(node.id, reported, totals))
    end
  end

  # Een agent van voor het reported_avail_*-veld meldt deze getallen niet. Die
  # nodes houden het oude gedrag: liever het bekende startpunt dan een node die
  # nergens meer voor in aanmerking komt omdat er nil binnenkwam.
  defp reported_capacity(%{
         reported_avail_vcpu: vcpu,
         reported_avail_ram_mb: ram,
         reported_avail_disk_gb: disk
       })
       when is_integer(vcpu) and is_integer(ram) and is_integer(disk) do
    %{vcpu: vcpu, ram_mb: ram, disk_gb: disk}
  end

  defp reported_capacity(_totals), do: nil

  # Daarbovenop een plafond dat de control plane zelf kent: het totaal min alles
  # wat er al aan VPS'en op staat of komt. Zonder dat kon een node die niet van
  # ons is altijd "leeg" melden en zo elke plaatsing winnen -- precies wat het
  # plafond in `Node` moet voorkomen, maar daar alleen tegen het totaal. Alleen
  # geheugen en schijf: vCPU mag de eigenaar overboeken (`vcpu_oversubscribe`),
  # dus totaal min toegezegd zegt daar niets.
  defp minus_held(node_id, reported, totals) do
    held = som_reserveringen(node_id, [:held])
    beloofd = som_reserveringen(node_id, [:held, :committed])

    %{
      available_vcpu: max(0, reported.vcpu - held.vcpu),
      available_ram_mb:
        reported.ram_mb |> Kernel.-(held.ram_mb) |> plafond(totals[:total_ram_mb], beloofd.ram_mb),
      available_disk_gb:
        reported.disk_gb
        |> Kernel.-(held.disk_gb)
        |> plafond(totals[:total_disk_gb], beloofd.disk_gb)
    }
  end

  defp plafond(vrij, totaal, beloofd) when is_integer(totaal),
    do: vrij |> min(totaal - beloofd) |> max(0)

  defp plafond(vrij, _totaal, _beloofd), do: max(0, vrij)

  defp som_reserveringen(node_id, statussen) do
    Repo.one(
      from r in Reservation,
        where: r.node_id == ^node_id and r.status in ^statussen,
        select: %{
          vcpu: coalesce(sum(r.vcpu), 0),
          ram_mb: coalesce(sum(r.ram_mb), 0),
          disk_gb: coalesce(sum(r.disk_gb), 0)
        }
    ) || %{vcpu: 0, ram_mb: 0, disk_gb: 0}
  end

  # Alleen nog voor een agent die geen reported_avail_* meldt: een node schrijft
  # zich in voordat hij capaciteit heeft gemeld, dus available_* begint op nil.
  defp maybe_init_available(attrs, %Node{available_vcpu: nil}, totals) do
    attrs
    |> Map.put(:available_vcpu, totals[:total_vcpu])
    |> Map.put(:available_ram_mb, totals[:total_ram_mb])
    |> Map.put(:available_disk_gb, totals[:total_disk_gb])
  end

  defp maybe_init_available(attrs, %Node{}, _totals), do: attrs

  @doc """
  Query (not executed) selecting `:online` nodes in `region_id` with a recent
  heartbeat. Shared with the scheduler so locking variants can build on top of it.
  """
  def online_nodes_in_region_query(region_id) do
    cutoff = Clock.shift(-@heartbeat_ttl_seconds)

    query =
      from n in Node,
        where:
          n.status == :online and
            not is_nil(n.last_heartbeat_at) and
            n.last_heartbeat_at >= ^cutoff

    if is_nil(region_id), do: query, else: where(query, [n], n.region_id == ^region_id)
  end

  @doc false
  def heartbeat_ttl_seconds, do: @heartbeat_ttl_seconds

  @doc """
  Flips stale `:online` nodes to `:offline`, returning `{count, _}`.

  A node whose agent has stopped reporting keeps `status: :online` in the database
  indefinitely — the `@heartbeat_ttl_seconds` TTL only hides it from the scheduler
  (see `online_nodes_in_region_query/1`), so the operator dashboard and status
  checks would still show a dead node as online. This reconciliation step makes
  that staleness explicit: it sets `status = :offline` for every node that is
  currently `:online` and whose `last_heartbeat_at` is either null or older than
  the heartbeat TTL.

  Only `:online` nodes are affected. `:draining`, `:pending` and already-`:offline`
  nodes are deliberately left untouched (e.g. an operator-initiated drain must not
  be undone by reconciliation), and `available_*` capacity — owned solely by the
  scheduler — is never modified. The update runs as a single `Repo.update_all`.

  See `mark_stale_nodes_offline/1` to pass an explicit cutoff (useful in tests).
  """
  @spec mark_stale_nodes_offline() :: {non_neg_integer(), nil}
  @spec mark_stale_nodes_offline(DateTime.t()) :: {non_neg_integer(), nil}
  def mark_stale_nodes_offline do
    mark_stale_nodes_offline(Clock.shift(-@heartbeat_ttl_seconds))
  end

  @doc """
  Like `mark_stale_nodes_offline/0`, but flips `:online` nodes whose
  `last_heartbeat_at` is null or strictly older than the given `cutoff` datetime.
  """
  def mark_stale_nodes_offline(%DateTime{} = cutoff) do
    query =
      from n in Node,
        where:
          n.status == :online and
            (is_nil(n.last_heartbeat_at) or n.last_heartbeat_at < ^cutoff)

    {count, _} = result = Repo.update_all(query, set: [status: :offline, updated_at: Clock.now()])

    if count > 0, do: Events.broadcast_changed(:nodes_offline)

    result
  end

  # Allow both string- and atom-keyed attribute maps for heartbeats.
  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
