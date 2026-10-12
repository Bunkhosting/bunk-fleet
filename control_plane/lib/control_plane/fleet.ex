defmodule ControlPlane.Fleet do
  @moduledoc """
  The Fleet context: regions, nodes, VPSes and capacity reservations that make up
  the federated VPS control plane.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Housekeeping
  alias ControlPlane.Fleet.Liveness
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Regions
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @doc "Zie `ControlPlane.Fleet.Regions.list_regions/0`."
  defdelegate list_regions(), to: Regions

  @doc "Zie `ControlPlane.Fleet.Regions.selectable_regions/1`."
  defdelegate selectable_regions(extra_ids \\ []), to: Regions

  @doc "Zie `ControlPlane.Fleet.Regions.list_regions_with_counts/0`."
  defdelegate list_regions_with_counts(), to: Regions

  @doc "Zie `ControlPlane.Fleet.Regions.update_region/2`."
  defdelegate update_region(region_id, attrs), to: Regions

  @doc "Zie `ControlPlane.Fleet.Regions.delete_region/1`."
  defdelegate delete_region(region_id), to: Regions

  @doc "Zie `ControlPlane.Fleet.Regions.get_region!/1`."
  defdelegate get_region!(id), to: Regions

  @doc "Zie `ControlPlane.Fleet.Regions.region_by_code/1`."
  defdelegate region_by_code(code), to: Regions

  @doc "Zie `ControlPlane.Fleet.Regions.create_region/1`."
  defdelegate create_region(attrs), to: Regions

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.list_nodes/1`."
  defdelegate list_nodes(opts \\ []), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.drain_node/2`."
  defdelegate drain_node(node_id, reason \\ nil), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.list_nodes_owned_by/1`."
  defdelegate list_nodes_owned_by(user), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.move_node_to_region/3`."
  defdelegate move_node_to_region(node_id, user, region_id), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.move_node_to_named_region/3`."
  defdelegate move_node_to_named_region(node_id, user, naam), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.Regions.ensure_region/1`."
  defdelegate ensure_region(naam), to: Regions

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.update_node_settings/3`."
  defdelegate update_node_settings(node_id, user, attrs), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.assign_node_owner/3`."
  defdelegate assign_node_owner(node_id, door, owner_id), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.node_owner?/2`."
  defdelegate node_owner?(node, user), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.resume_node/1`."
  defdelegate resume_node(node_id), to: NodeAdmin

  @doc "Zie `ControlPlane.Fleet.NodeAdmin.delete_node/1`."
  defdelegate delete_node(node_id), to: NodeAdmin

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

  @doc "Zie `ControlPlane.Fleet.Regions.auto_region_id/1`."
  defdelegate auto_region_id(request), to: Regions

  @doc "Zie `ControlPlane.Fleet.Regions.available_regions/0`."
  defdelegate available_regions(), to: Regions

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
