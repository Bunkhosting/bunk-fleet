defmodule ControlPlane.Fleet.NodeAdmin do
  @moduledoc """
  Het beheer van nodes: wat een beheerder en een node-eigenaar met een machine
  in de vloot kunnen doen.

  Een beheerder ziet alle nodes (`list_nodes/1`), sluit er een voor nieuwe
  VPS'en (`drain_node/2`), opent hem weer (`resume_node/1`) of haalt een lege
  node uit de vloot (`delete_node/1`). Een node-eigenaar verplaatst zijn node
  naar een andere locatie, wijzigt de instellingen of draagt hem over; die
  functies controleren zelf of degene die het vraagt de eigenaar is
  (`node_owner?/2`), zodat geen tweede ingang om dat slot heen kan.
  """
  import Ecto.Query

  alias ControlPlane.Accounts.User
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Regions
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

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
         {:ok, region} <- Regions.ensure_region(naam) do
      move_node_to_region(node.id, user, region.id)
    else
      {:error, reden} -> {:error, reden}
    end
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
  Draagt een node over, of haalt de eigenaar eraf.

  Wie mag dat: de eigenaar zelf, en verder niemand. Een node die nog géén
  eigenaar heeft, krijgt er een via `assign_unowned_node/2` in het beheerpaneel
  -- anders zou een node die met een beheerderstoken is ingeschreven er nooit een
  kunnen krijgen -- maar zodra er een eigenaar is, is die de enige die hem kan
  overdragen.

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
         :ok <- if(node_owner?(node, door), do: :ok, else: {:error, :forbidden}),
         :ok <- known_user(owner_id) do
      zet_eigenaar(node, owner_id)
    end
  end

  @doc """
  Geeft een node die nog geen eigenaar heeft er een. Alleen voor het
  beheerpaneel.

  Dit is het enige moment waarop iemand anders dan de eigenaar over een node
  gaat, en het hoort daarom achter dezelfde drempel als elke andere
  beheerhandeling: een sessie met tweede factor en een regel in het auditlog.
  Het zat eerst in `assign_node_owner/3` als uitzondering voor de rol
  `:admin`, op de gewone gebruikersroute, en daar gold geen van beide.
  """
  @spec assign_unowned_node(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Node.t()}
          | {:error, :not_found | :already_owned | :unknown_user | Ecto.Changeset.t()}
  def assign_unowned_node(node_id, owner_id) do
    with {:ok, node} <- fetch_node(node_id),
         :ok <- if(is_nil(node.owner_id), do: :ok, else: {:error, :already_owned}),
         :ok <- known_user(owner_id) do
      zet_eigenaar(node, owner_id)
    end
  end

  defp zet_eigenaar(%Node{} = node, owner_id) do
    node
    |> Node.changeset(%{owner_id: owner_id})
    |> Repo.update()
    |> tap_ok(fn _ -> Events.broadcast_changed(:node) end)
    |> met_regio()
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

  # Runs `fun` only when `result` is `{:ok, value}`, then returns `result`
  # unchanged. Used to fire a best-effort PubSub event as a side-effect after a
  # successful DB write without altering the function's return value.
  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result
end
