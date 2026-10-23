defmodule ControlPlane.Fleet.Scheduler do
  @moduledoc """
  Capacity-aware placement of VPS requests onto fleet nodes.

  The scheduler selects an `:online` node in the requested region that has enough
  live available capacity for the request, picks the *least-loaded* fitting node
  (the one with the most headroom remaining after placement), then atomically
  decrements that node's available capacity and records a `:held`
  `ControlPlane.Fleet.Reservation`.

  To avoid overcommitting a node when two placement requests race, candidate rows
  are read with `SELECT ... FOR UPDATE` inside a transaction so concurrent
  schedulers serialize on the same node rows.
  """
  import Ecto.Query

  alias ControlPlane.Fleet.Liveness
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Repo
  alias Ecto.Multi

  @type request :: %{
          required(:region_id) => binary(),
          required(:vcpu) => non_neg_integer(),
          required(:ram_mb) => non_neg_integer(),
          required(:disk_gb) => non_neg_integer()
        }

  @doc """
  Places `request` onto the best-fitting online node in its region.

  `request` is a map with `:region_id`, `:vcpu`, `:ram_mb` and `:disk_gb`.

  Options:

    * `:vps_id` - associate the created reservation with this VPS.

  Returns `{:ok, %{node: node, reservation: reservation}}` on success or
  `{:error, :no_capacity}` when no node in the region can fit the request.
  """
  @spec place(request(), keyword()) ::
          {:ok, %{node: Node.t(), reservation: Reservation.t()}} | {:error, :no_capacity}
  def place(request, opts \\ []) do
    multi =
      Multi.new()
      # 1. Lock and load the fitting candidates in this region. Locking here means
      #    any concurrent placement targeting the same nodes blocks until we commit
      #    or roll back, preventing two requests from both reading stale capacity.
      |> Multi.run(:candidates, fn repo, _changes ->
        {:ok, lock_candidates(repo, request)}
      end)
      # 2. Pick the least-loaded fitting node (or fail with :no_capacity).
      |> Multi.run(:node, fn _repo, %{candidates: candidates} ->
        case pick_node(candidates, request) do
          nil -> {:error, :no_capacity}
          node -> {:ok, node}
        end
      end)
      # 3. Decrement the chosen node's available capacity.
      |> Multi.update(:decrement, fn %{node: node} ->
        decrement_changeset(node, request)
      end)
      # 4. Record the held reservation against that node.
      |> Multi.insert(:reservation, fn %{node: node} ->
        reservation_changeset(node, request, opts)
      end)

    case Repo.transaction(multi) do
      {:ok, %{decrement: node, reservation: reservation}} ->
        {:ok, %{node: node, reservation: reservation}}

      {:error, :node, :no_capacity, _changes} ->
        {:error, :no_capacity}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Load online nodes in the region that fit the request, locking the rows FOR
  # UPDATE so capacity decisions are serialized across concurrent schedulers.
  defp lock_candidates(repo, request) do
    Liveness.online_nodes_in_region_query(request.region_id)
    |> where(^fits_condition(request))
    # Deterministic lock-acquisition order so concurrent schedulers never grab
    # the same candidate rows in opposite orders (deadlock avoidance).
    |> order_by([n], asc: n.id)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  @doc """
  Ecto-conditie: de node heeft genoeg vrije capaciteit voor `request`
  (`:vcpu`, `:ram_mb`, `:disk_gb`). Dit is DE plaatsingsregel; `lock_candidates/2`
  en `fits?/2` gebruiken hem allebei, zodat de catalogus nooit iets anders
  belooft dan de scheduler doet.
  """
  def fits_condition(%{vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb}) do
    # Eerste horde: wat het control plane zelf bijhoudt (available_*).
    # Tweede horde: wat de agent zelf nog vrij ziet. available_* begint bij het
    # totaal van de machine en weet niets van wat daar al op draaide voordat
    # Bunk er was — op de eerste node scheelde dat 7 GB. is_nil laat een node
    # door die nog niets heeft gemeld; die stond er voorheen ook, en hem nu
    # blokkeren zou een werkende node onbruikbaar maken op een ontbrekend cijfer.
    dynamic(
      [n],
      n.available_vcpu >= ^vcpu and
        n.available_ram_mb >= ^ram_mb and
        n.available_disk_gb >= ^disk_gb and
        (is_nil(n.reported_avail_vcpu) or n.reported_avail_vcpu >= ^vcpu) and
        (is_nil(n.reported_avail_ram_mb) or n.reported_avail_ram_mb >= ^ram_mb) and
        (is_nil(n.reported_avail_disk_gb) or n.reported_avail_disk_gb >= ^disk_gb)
    )
  end

  @doc """
  Dezelfde regel als `fits_condition/1`, maar op een al geladen node. Moet altijd
  hetzelfde antwoord geven (zie de overeenkomsttest in de scheduler-tests).
  """
  @spec fits?(Node.t(), request() | map()) :: boolean()
  def fits?(%Node{} = n, %{vcpu: vcpu, ram_mb: ram_mb, disk_gb: disk_gb}) do
    n.available_vcpu >= vcpu and n.available_ram_mb >= ram_mb and
      n.available_disk_gb >= disk_gb and
      reported_ok?(n.reported_avail_vcpu, vcpu) and
      reported_ok?(n.reported_avail_ram_mb, ram_mb) and
      reported_ok?(n.reported_avail_disk_gb, disk_gb)
  end

  defp reported_ok?(nil, _gevraagd), do: true
  defp reported_ok?(gemeld, gevraagd), do: gemeld >= gevraagd

  @doc """
  Alle nodes die nu meedoen voor plaatsing, in elke regio. Eén query; voor de
  publieke catalogus, die dit per pakket met `fits?/2` evalueert.
  """
  @spec placeable_nodes() :: [Node.t()]
  def placeable_nodes do
    Repo.all(Liveness.online_nodes_in_region_query(nil))
  end

  # Choose the least-loaded fitting node: the one that retains the most headroom
  # after the request is subtracted. We score by the sum of the fractions of each
  # resource that would remain free, so a node that would be left most idle wins.
  defp pick_node([], _request), do: nil

  defp pick_node(candidates, request) do
    Enum.max_by(candidates, &Node.headroom_score(&1, request))
  end

  defp decrement_changeset(%Node{} = node, request) do
    Node.subtract_capacity_changeset(node, request)
  end

  defp reservation_changeset(%Node{} = node, request, opts) do
    Reservation.changeset(%Reservation{}, %{
      node_id: node.id,
      vps_id: Keyword.get(opts, :vps_id),
      vcpu: request.vcpu,
      ram_mb: request.ram_mb,
      disk_gb: request.disk_gb,
      status: :held
    })
  end
end
