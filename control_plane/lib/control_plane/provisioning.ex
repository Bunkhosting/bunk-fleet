defmodule ControlPlane.Provisioning do
  @moduledoc """
  Drives the lifecycle of a VPS from request to running instance:

    1. `create_vps/1` records the VPS, asks the `ControlPlane.Fleet.Scheduler` to
       place it onto a node (holding capacity), and enqueues a `:provision`
       `ControlPlane.Fleet.Command` for that node's agent.
    2. The node's agent polls `deliverable_commands_for_node/1` (via the command
       API), each marked delivered with `mark_delivered/1`. A command lost to an
       agent crash (delivered but never resolved) is redelivered after a TTL.
    3. The agent reports the outcome through `apply_result/2`, which finalises both
       the command and the VPS, committing or releasing the held reservation.
  """
  import Ecto.Query, warn: false
  require Logger

  alias ControlPlane.Clock
  alias ControlPlane.Console.Keys
  alias ControlPlane.Credits

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.IpPool
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.PortPool
  alias ControlPlane.Fleet.Scheduler
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Locks
  alias ControlPlane.Net
  alias ControlPlane.Provisioning.Reservations
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions
  alias Ecto.Multi

  @typedoc """
  What a lifecycle call hands back: the VPS row and the command dispatched to its
  node. `command` is `nil` when nothing needed dispatching — an already-stopped
  VPS asked to stop, or a teardown with no VM behind it.
  """
  @type dispatch :: %{vps: Vps.t(), command: Command.t() | nil}

  @typedoc """
  Why a lifecycle call refused. Every one of these becomes an API error code, so
  adding one here means adding a translation in the frontend too.
  """
  @type refusal ::
          :not_found
          | :not_provisioned
          | :no_node
          | :no_capacity
          | :already_deleting
          | :quota_exceeded
          | :insufficient_credits
          | :port_pool_exhausted
          | {:invalid_status, atom()}

  # How long a `:delivered` command may sit without a reported result before it
  # is considered lost (agent crashed mid-flight) and becomes eligible for
  # redelivery. Redelivery is safe only because the Go agent treats commands
  # idempotently (a re-issued provision/delete for an already-handled VM is a
  # no-op that re-reports the same result).
  @redelivery_ttl_seconds 90

  # Boven deze grens wordt een commando niet meer uitgedeeld maar gemeld. Niet
  # als mislukt gemarkeerd: het werk is waarschijnlijk juist wél gedaan -- er is
  # alleen nooit een resultaat teruggekomen -- en zo'n commando alsnog laten
  # falen zou een draaiende machine terugbetalen en opruimen. Melden, en een
  # mens laat beslissen. Zelfde afweging als in `Fleet.Drift`.
  @max_afleveringen 5

  @doc """
  Creates a VPS and dispatches a provision command to the node it is placed on.

  This:

    * inserts the `Vps` in the `:queued` state (persisted up front so that even a
      placement failure leaves a durable, `:failed` record),
    * asks the scheduler to place it (which holds capacity on a node), and
    * on success, in one transaction, moves the VPS to `:provisioning`, pins it to
      the chosen node, and enqueues a `:provision` `Command` carrying the agent's
      snake_case payload.

  Returns `{:ok, %{vps: vps, command: command}}` on success. If no node can fit the
  request the VPS is marked `:failed` and `{:error, :no_capacity}` is returned.

  Recognised keys: `:region_id`, `:name`, `:vcpu`, `:ram_mb`, `:disk_gb`,
  `:owner_email`, `:template_id`, `:ssh_keys` (default `[]`), `:cloud_init`
  (default `%{}`), `:ip_config` (default `nil`).
  """
  @spec create_vps(map()) :: {:ok, dispatch()} | {:error, refusal() | Ecto.Changeset.t()}
  def create_vps(attrs) do
    req = placement_request(attrs)

    # Persist the VPS up front so that even a placement failure leaves a durable,
    # `:failed` record for the customer rather than rolling everything back.
    with {:ok, vps} <- Repo.insert(vps_changeset(attrs)) do
      place_and_dispatch(vps, req, attrs)
    end
  end

  @doc """
  Fails VPSes that were persisted but never dispatched, and says how many.

  `create_vps/1` inserts the row `:queued` and then places it. Between those two
  the control plane can stop — a deploy, a crash — and what is left is a row
  nobody will ever act on: no command, no reservation, no node, and a customer
  who has already been charged. It counts against their quota and shows in their
  dashboard as something about to happen, forever.

  Marking it `:failed` is the honest end state: the customer can see it went
  wrong and delete it, and it stops occupying a quota slot. It is deliberately
  not refunded here. The ledger records a charge against a user, not against a
  VPS, so a sweeper cannot tell which entry to reverse without guessing — and
  guessing with someone's money is worse than telling a person to look.
  """
  @spec fail_stuck_queued_vpses(non_neg_integer()) :: non_neg_integer()
  def fail_stuck_queued_vpses(grace_seconds \\ 600) do
    cutoff = DateTime.utc_now() |> DateTime.add(-grace_seconds, :second)

    stuck =
      Repo.all(
        from v in Vps,
          as: :vps,
          where: v.status == :queued and v.inserted_at < ^cutoff,
          # A row with a command is mid-dispatch, not abandoned.
          where: not exists(from c in Command, where: c.vps_id == parent_as(:vps).id, select: 1),
          select: v.id
      )

    Enum.each(stuck, fn vps_id ->
      # The charge carries the VPS id since the ledger learned about machines, so
      # the money can go back here instead of in a sentence telling a person to
      # go and look for it.
      refunded = Credits.refund_charge_for_vps(vps_id)

      Logger.error(
        "vps #{vps_id} was queued but never dispatched; failing it. " <>
          if(refunded, do: "The charge has been refunded.", else: "No charge was found for it.")
      )
    end)

    {count, _} =
      Repo.update_all(
        from(v in Vps, where: v.id in ^stuck),
        set: [status: :failed, updated_at: Clock.now()]
      )

    if count > 0, do: Events.broadcast_changed(:vps)
    count
  end

  @doc """
  Verwijdert afgehandelde commando's ouder dan `dagen`, en geeft terug hoeveel.

  De tabel werd nooit opgeschoond. Elk commando dat ooit naar een node ging staat
  er nog, met een payload en een resultaat per rij, en dat groeit met het aantal
  VPS'en maal het aantal handelingen dat eraan is verricht. Het enige wat er ooit
  nog naar kijkt is een mens die uitzoekt wat er een keer misging, en die kijkt
  niet drie maanden terug.

  Alleen `:done` en `:failed` gaan weg. Een commando dat nog `:pending` of
  `:delivered` is, is werk dat nog moet gebeuren -- hoe oud het ook is. Een oude
  rij in die toestand betekent dat er iets vastzit, en dat is een reden om te
  kijken, niet om te wissen.

  Per aanroep een begrensd aantal rijen. De eerste keer dat dit draait staan er
  mogelijk honderdduizenden; die in één transactie verwijderen houdt een lock
  vast terwijl klanten op hun paneel zitten te wachten. Wat blijft staan gaat de
  volgende ronde mee.
  """
  @spec purge_old_commands(pos_integer(), pos_integer()) :: non_neg_integer()
  def purge_old_commands(dagen \\ 90, hoogstens \\ 5_000) do
    cutoff = Clock.shift(-dagen * 24 * 3600)

    oud =
      Repo.all(
        from c in Command,
          where: c.status in [:done, :failed] and c.updated_at < ^cutoff,
          select: c.id,
          limit: ^hoogstens
      )

    case oud do
      [] ->
        0

      ids ->
        {aantal, _} = Repo.delete_all(from c in Command, where: c.id in ^ids)
        aantal
    end
  end

  @doc """
  Fails VPSes still `:provisioning` on a node that has gone away, and returns how
  many.

  `fail_stuck_queued_vpses/1` only looks at `:queued` -- rows the control plane
  never managed to dispatch. Once a placement succeeds the VPS goes
  `:provisioning` with a command behind it, and from there the only way out is
  the agent reporting a result. If the node never comes back, nobody ever
  reports: the row stays "bezig" in the panel forever, its reservation stays
  `:held` so the node looks fuller than it is even after it returns, and the
  customer stays charged for a machine that does not exist.

  The trigger is deliberately narrow -- the node is `:offline` (the heartbeat
  sweeper has already decided it is gone) and the provision command has sat
  unresolved past the grace. A node that is merely slow stays `:online` and its
  command keeps being redelivered, which is the existing recovery path and is
  better than this one.

  The grace is half an hour: far past the 120-second heartbeat TTL, so a reboot
  or a brief network cut never reaches this code.

  It goes through `apply_result/2` with a synthesised failure rather than
  updating the rows here, so the refund, the reservation release and the
  capacity restore are literally the same code that runs when an agent reports a
  failed provision. A second implementation of that path would be a second place
  for the money to go wrong.

  What this cannot do is clean up a half-built VM on the node, because the agent
  never told us a vm_id. If the node returns with a guest we do not know about,
  `ControlPlane.Fleet.Drift` is what reports it.
  """
  @spec fail_stuck_provisioning_vpses(non_neg_integer()) :: non_neg_integer()
  def fail_stuck_provisioning_vpses(grace_seconds \\ 1800) do
    cutoff = Clock.shift(-grace_seconds)

    gestrand =
      Repo.all(
        from c in Command,
          join: v in Vps,
          on: v.id == c.vps_id,
          join: n in Node,
          on: n.id == c.node_id,
          where: c.kind == :provision and c.status in [:pending, :delivered],
          where: v.status == :provisioning,
          where: n.status == :offline,
          where: c.inserted_at < ^cutoff
      )

    Enum.each(gestrand, fn command ->
      Logger.error(
        "vps #{command.vps_id} hangt in :provisioning op node #{command.node_id}, " <>
          "die offline is; de bestelling wordt als mislukt afgehandeld en terugbetaald"
      )

      apply_result(command, %{
        "status" => "failed",
        "error" => "node unreachable: provision never reported a result"
      })
    end)

    length(gestrand)
  end

  @doc """
  Re-dispatches teardowns that failed, and returns how many it retried.

  A delete whose command fails leaves the VPS `:deleting` with a live VM still
  running on the node. It is recoverable — asking to delete again dispatches a
  fresh command — but the dashboard shows "being deleted" and offers no second
  button, so the nudge has to come from here.

  The spacing doubles with each failure: five minutes after the first, ten after
  the second, and so on to a ceiling. That is deliberate in both directions. A
  transient error — a busy storage, a node mid-reboot — clears on the next
  attempt; a real one (a VM the hypervisor will not release) stops generating a
  command every thirty seconds while still being retried hours later, when the
  node that was down for maintenance comes back.

  There is no give-up state on purpose. Marking the VPS `:failed` would let the
  customer clear it from their list while its VM kept running and its capacity
  stayed booked — tidy for them, a leak for the fleet.
  """
  @spec retry_stuck_deletes(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def retry_stuck_deletes(grace_seconds \\ 300, max_backoff_seconds \\ 6 * 3600) do
    now = DateTime.utc_now()

    candidates =
      Repo.all(
        from v in Vps,
          as: :vps,
          where: v.status == :deleting and not is_nil(v.node_id),
          where:
            not exists(
              from c in Command,
                where:
                  c.vps_id == parent_as(:vps).id and c.kind == :delete and
                    c.status in [:pending, :delivered],
                select: 1
            )
      )

    # De mislukkingen van alle kandidaten in één query. Stond dit per kandidaat,
    # dan deed de reconciler elke dertig seconden een query per VPS die op
    # verwijderen wacht -- en dat is precies de situatie waarin er meer dan een
    # paar zijn: een node die weg is, met alles erop in :deleting.
    mislukkingen = mislukte_deletes(Enum.map(candidates, & &1.id))

    candidates
    |> Enum.filter(
      &due_for_delete_retry?(&1, mislukkingen, now, grace_seconds, max_backoff_seconds)
    )
    |> Enum.map(fn vps ->
      Logger.error("retrying the failed teardown of vps #{vps.id}")
      dispatch_delete(vps)
    end)
    |> length()
  end

  # Per VPS: hoeveel delete-commando's er mislukt zijn en wanneer de laatste dat
  # deed. Meer heeft de afweging hieronder niet nodig.
  defp mislukte_deletes([]), do: %{}

  defp mislukte_deletes(vps_ids) do
    Repo.all(
      from c in Command,
        where: c.vps_id in ^vps_ids and c.kind == :delete and c.status == :failed,
        group_by: c.vps_id,
        select: {c.vps_id, count(c.id), type(max(c.updated_at), :utc_datetime)}
    )
    |> Map.new(fn {vps_id, aantal, laatste} -> {vps_id, {aantal, laatste}} end)
  end

  defp due_for_delete_retry?(%Vps{} = vps, mislukkingen, now, grace_seconds, max_backoff_seconds) do
    case Map.get(mislukkingen, vps.id) do
      nil ->
        false

      {aantal, laatste} ->
        # 5 min, 10, 20, 40… so a genuinely broken teardown stops churning while
        # still being retried long after a node comes back. De exponent wordt
        # afgetopt voordat hij wordt uitgerekend: de uitkomst gaat toch door
        # `min/2`, en 2^300 uitrekenen om hem daarna weg te gooien is zonde.
        backoff =
          min(grace_seconds * Integer.pow(2, min(aantal - 1, 32)), max_backoff_seconds)

        DateTime.diff(now, laatste, :second) >= backoff
    end
  end

  @doc """
  Creates a VPS on behalf of an authenticated owner, enforcing the per-owner quota
  and stamping ownership from the trusted session (never the request body).

  Any `owner_id`/`owner_email` present in `attrs` is dropped and replaced with the
  caller's, so a user cannot provision a VPS into someone else's account. Returns
  `{:error, :quota_exceeded}` when the owner already holds the maximum number of
  live (non-`:deleted`/non-`:failed`) VPSes.
  """
  @spec create_vps_for_owner(%{id: binary(), email: binary()}, map()) ::
          {:ok, dispatch()} | {:error, refusal() | Ecto.Changeset.t()}
  def create_vps_for_owner(%{id: owner_id, email: email}, attrs) do
    full =
      attrs
      |> Map.drop([:owner_id, "owner_id", :owner_email, "owner_email"])
      |> Map.put(:owner_id, owner_id)
      |> Map.put(:owner_email, email)

    # Placement + dispatch deliberately run AFTER the insert commits — each in its own
    # top-level transaction, never nested inside this one. Ecto uses no savepoint
    # for a nested transaction, so a normal placement failure (fleet full, IP
    # collision) inside the scheduler's `Repo.transaction` would otherwise poison
    # this enclosing transaction, and the following `mark_vps_failed`/reservation-
    # release update would raise "current transaction is aborted" → HTTP 500
    # instead of a clean {:error, :no_capacity} (→ 409).
    with {:ok, %Vps{} = vps} <- insert_within_quota(owner_id, full),
         {:ok, %{vps: placed}} <- place_and_dispatch(vps, placement_request(full), full) do
      start_subscription(placed, owner_id, full)
      {:ok, %{vps: placed}}
    end
  end

  # The quota gate and the durable :queued insert, in one short transaction: the
  # per-owner advisory lock (auto-released at commit) serialises concurrent
  # creates against the quota check, so two cannot both pass the cap.
  defp insert_within_quota(owner_id, attrs) do
    Repo.transaction(fn ->
      :ok = Locks.take(Repo, :owner_quota, owner_id)

      if count_live_vpses(owner_id) >= max_vpses_per_owner() do
        Repo.rollback(:quota_exceeded)
      else
        insert_or_rollback(attrs)
      end
    end)
  end

  defp insert_or_rollback(attrs) do
    case Repo.insert(vps_changeset(attrs)) do
      {:ok, vps} -> vps
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Callers arrive from two directions: a controller with string keys off the
  # wire, and internal code with atom keys. Both are accepted here, at the one
  # boundary, so nothing further in returns to guessing which it got.
  defp placement_request(attrs) do
    %{
      region_id: field(attrs, :region_id),
      vcpu: field(attrs, :vcpu),
      ram_mb: field(attrs, :ram_mb),
      disk_gb: field(attrs, :disk_gb)
    }
  end

  defp field(attrs, key), do: attrs[key] || attrs[Atom.to_string(key)]

  defp start_subscription(%Vps{} = vps, owner_id, attrs) do
    Subscriptions.create_for_vps(vps, owner_id, field(attrs, :package_id))
  end

  @doc """
  Counts an owner's live VPSes — everything except `:deleted`/`:failed`, which no
  longer occupy capacity and so don't count against quota.
  """
  @spec count_live_vpses(binary()) :: non_neg_integer()
  def count_live_vpses(owner_id) do
    Repo.one(
      from v in Vps,
        where: v.owner_id == ^owner_id and v.status not in [:deleted, :failed],
        select: count(v.id)
    )
  end

  defp max_vpses_per_owner do
    Application.get_env(:control_plane, :max_vpses_per_owner, 10)
  end

  defp default_template_id do
    Application.get_env(:control_plane, :default_template_id, 9000)
  end

  # The in-browser console connects to each VPS over SSH with the platform console
  # key, so its public key is injected into every VPS via cloud-init (next to the
  # customer's own keys). Empty list when no console key is configured.
  # De sleutel die in de `authorized_keys` van déze VPS komt. Heeft hij een eigen
  # sleutelpaar, dan alleen die -- de gedeelde erbij zetten zou het hele punt
  # ongedaan maken.
  defp console_keys_voor(%Vps{console_key_public: publiek})
       when is_binary(publiek) and publiek != "",
       do: [publiek]

  defp console_keys_voor(_vps), do: console_public_keys()

  defp console_public_keys do
    case (Application.get_env(:control_plane, :console) || [])[:ssh_public_key] do
      key when is_binary(key) and key != "" -> [key]
      _ -> []
    end
  end

  defp place_and_dispatch(%Vps{} = vps, req, attrs) do
    case Scheduler.place(req, vps_id: vps.id) do
      {:ok, %{node: node}} ->
        # IP allocation, the VPS update and the command insert run in ONE
        # transaction. Allocation takes a per-node advisory lock and the
        # `vpses_active_node_ip_uidx` unique index is the DB backstop, so two
        # concurrent creates on the same node can never share an address.
        multi =
          Multi.new()
          |> Multi.run(:allocation, fn repo, _changes -> allocate_ip(repo, attrs, node) end)
          |> Multi.run(:vps, fn repo, %{allocation: {_attrs, ip}} ->
            vps
            |> Vps.changeset(%{node_id: node.id, status: :provisioning, ip_address: ip})
            |> repo.update()
          end)
          # A customer needs somewhere to connect. The node's own address plus an
          # allocated port is it — in the same transaction as the IP, so a VPS
          # never exists having been promised an endpoint it did not get.
          |> Multi.run(:ssh_forward, fn repo, %{vps: vps} ->
            allocate_ssh_forward(repo, node, vps)
          end)
          |> Multi.insert(:command, fn %{vps: vps, allocation: {attrs, _ip}} ->
            Command.changeset(%Command{}, %{
              node_id: node.id,
              vps_id: vps.id,
              kind: :provision,
              status: :pending,
              payload: provision_payload(vps, attrs, node)
            })
          end)

        case Repo.transaction(multi) do
          {:ok, %{vps: vps, command: command}} ->
            Events.broadcast_changed(:vps)
            {:ok, %{vps: vps, command: command}}

          {:error, _step, reason, _changes} ->
            # Any failure here is AFTER the scheduler reserved capacity, so release
            # the held reservation and restore the node's capacity (else it leaks).
            {:ok, _} = fail_and_release_reservation(vps.id)
            Events.broadcast_changed(:vps)
            {:error, reason}
        end

      {:error, :no_capacity} ->
        {:ok, _failed} = mark_vps_failed(vps)
        # The VPS was persisted (now :failed) so the dashboard should still update.
        Events.broadcast_changed(:vps)
        {:error, :no_capacity}
    end
  end

  # Resolves the VPS IP inside the dispatch transaction. An explicit ip_config
  # (admin override) wins; otherwise a per-node advisory lock serialises pool
  # allocation so concurrent creates can't pick the same address.
  defp allocate_ip(repo, attrs, node) do
    cfg = field(attrs, :ip_config)

    if cfg do
      # Derive ip_address from the explicit config (or a passed ip_address) so the
      # control plane's record IS the assigned address — the authoritative console
      # target — rather than leaving it nil and later trusting the agent's report.
      ip = field(attrs, :ip_address) || Net.from_ip_config(cfg)
      {:ok, {Map.put(attrs, :ip_address, ip), ip}}
    else
      :ok = Locks.take(repo, :node_allocation, node.id)

      case IpPool.allocate(node) do
        {:ok, %{ip: ip, config: cfg}} ->
          {:ok, {attrs |> Map.put(:ip_config, cfg) |> Map.put(:ip_address, ip), ip}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Every VPS gets an SSH forward at provision time rather than on request: it is
  # the one port nobody can do without, and a customer discovering after the fact
  # that they have to go and ask for SSH is a customer who bought the wrong thing.
  #
  # A node with no public address gets no forward and no error. That is not a
  # failure — it is a node nothing outside can reach yet, and the API says so
  # rather than inventing an endpoint.
  defp allocate_ssh_forward(_repo, %Node{public_host: nil}, _vps), do: {:ok, nil}

  defp allocate_ssh_forward(repo, %Node{} = node, %Vps{} = vps) do
    case PortPool.allocate(repo, node, %{vps_id: vps.id, target_port: 22, purpose: "ssh"}) do
      {:ok, forward} ->
        {:ok, forward}

      {:error, :port_pool_exhausted} = error ->
        error

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Marks a VPS :failed and releases its held reservation, returning the freed
  # capacity to the node (mirrors the agent-reported provision-failure path).
  defp fail_and_release_reservation(vps_id) do
    Multi.new()
    |> Multi.run(:vps, fn repo, _changes ->
      repo.get!(Vps, vps_id) |> Vps.changeset(%{status: :failed}) |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      Reservations.release(repo, Reservations.held(repo, vps_id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      Reservations.restore_capacity(repo, reservation)
    end)
    |> Repo.transaction()
  end

  @doc """
  Begins teardown of a VPS by dispatching a `:delete` command to its node.

  In one transaction this moves the VPS to `:deleting` and enqueues a `:delete`
  `Command` carrying the provider VM id for the node's agent to destroy. The
  reservation is only released later, once the agent reports the delete `done`
  (see `apply_result/2`), so capacity is not freed before the VM is actually gone.

  Returns `{:ok, %{vps: vps, command: command}}`, or `{:error, :not_found}` if no
  VPS with `vps_id` exists, or `{:error, :no_node}` if the VPS was never placed
  on a node / provisioned (no `node_id` or `provider_vm_id`) and so has nothing
  for an agent to delete.
  """
  @spec delete_vps(binary()) :: {:ok, dispatch() | map()} | {:error, refusal()}
  def delete_vps(vps_id) do
    # Deleting a VPS ends its subscription — do it up front so recurring billing
    # stops immediately, even while an async teardown is still in flight.
    # Idempotent: a no-op if it's already cancelled or the VPS doesn't exist.
    _ = Subscriptions.cancel_for_vps(vps_id)

    case Repo.get(Vps, vps_id) do
      nil ->
        {:error, :not_found}

      %Vps{status: :deleted} ->
        {:error, :already_deleting}

      %Vps{status: :deleting} = vps ->
        redispatch_delete(vps)

      # A :failed VPS has no live VM and no held reservation (the reservation, if
      # any, was already released when provisioning failed), so it can be cleaned
      # up directly — no agent round-trip needed.
      %Vps{status: :failed} = vps ->
        mark_vps_deleted(vps)

      # Not yet scheduled to a node — no VM and no held reservation, so it can be
      # cleaned up directly. Lets a customer cancel a VPS still waiting for capacity.
      %Vps{node_id: nil} = vps ->
        mark_vps_deleted(vps)

      # Scheduled (capacity reserved) but no live VM recorded yet.
      %Vps{provider_vm_id: nil} = vps ->
        teardown_unprovisioned(vps)

      %Vps{} = vps ->
        dispatch_delete(vps)
    end
  end

  # Already :deleting: only block if a delete command is still in flight. If a
  # previous delete terminally failed (e.g. a transient Proxmox error), allow a
  # fresh attempt so a VPS can never get permanently stuck undeletable.
  defp redispatch_delete(vps) do
    if in_flight?(vps.id, :delete),
      do: {:error, :already_deleting},
      else: dispatch_delete(vps)
  end

  # If the provision command is still in flight (delivered to the agent), the
  # agent may be mid-CreateVM; force-failing it now would orphan the VM it
  # produces AND double-count the freed capacity. Defer: mark :deleting and let
  # the provision-done result run the compensating teardown. Only when nothing is
  # in flight is it safe to cancel-and-release immediately.
  defp teardown_unprovisioned(vps) do
    if provision_in_flight?(vps.id),
      do: defer_teardown(vps),
      else: cancel_and_release(vps)
  end

  # True if a command of this kind for this VPS is queued or already with the
  # agent, and so has not reported back yet.
  defp in_flight?(vps_id, kind) do
    Repo.exists?(
      from c in Command,
        where: c.vps_id == ^vps_id and c.kind == ^kind and c.status in [:pending, :delivered]
    )
  end

  # A provision command already handed to the agent (:delivered). Distinct from a
  # merely :pending one, which the agent has not started — that one is safe to
  # cancel outright.
  # Deliberately narrower than in_flight?/2: only :delivered counts, not
  # :pending. A provision still sitting in the queue has produced no VM, so it
  # can be cancelled outright; one the agent has taken may be mid-CreateVM, and
  # failing that now would orphan whatever it is about to produce.
  defp provision_in_flight?(vps_id) do
    Repo.exists?(
      from c in Command,
        where: c.vps_id == ^vps_id and c.kind == :provision and c.status == :delivered
    )
  end

  # Record delete intent without failing the in-flight provision or releasing
  # capacity. The provision result (see finalize_vps/4, :provision/:done) then
  # dispatches a compensating :delete for whatever VM the agent created and frees
  # capacity only once that delete confirms — so nothing is orphaned or
  # double-counted.
  defp defer_teardown(%Vps{} = vps) do
    case vps |> Vps.changeset(%{status: :deleting}) |> Repo.update() do
      {:ok, vps} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: nil}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Moves the VPS to :deleting and enqueues a :delete command for its node's agent.
  defp dispatch_delete(%Vps{} = vps) do
    multi =
      Multi.new()
      |> Multi.update(:vps, Vps.changeset(vps, %{status: :deleting}))
      |> Multi.insert(:command, fn %{vps: vps} ->
        Command.changeset(%Command{}, %{
          node_id: vps.node_id,
          vps_id: vps.id,
          kind: :delete,
          status: :pending,
          payload: %{"vm_id" => vps.provider_vm_id}
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{vps: vps, command: command}} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: command}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Dispatches a power command (`:start`/`:stop`/`:pause`/`:resume`) to a VPS's node.

  Guards on the VPS's current status so only valid transitions are issued: start
  from `:stopped`; stop from `:active`/`:paused`; pause from `:active`; resume from
  `:paused`. The VPS must be placed and provisioned (`node_id` + `provider_vm_id`).
  The status only changes once the agent reports the command done (see
  `apply_result/2`), so the dashboard reflects the real hypervisor state.

  Returns `{:ok, %{vps: vps, command: command}}`, or `{:error, reason}` where reason
  is `:not_found`, `:not_provisioned`, or `{:invalid_status, status}`.
  """
  @spec start_vps(binary()) :: {:ok, dispatch()} | {:error, refusal()}
  def start_vps(vps_id), do: dispatch_power(vps_id, :start, [:stopped])
  @spec stop_vps(binary()) :: {:ok, dispatch()} | {:error, refusal()}
  def stop_vps(vps_id), do: dispatch_power(vps_id, :stop, [:active, :paused])
  @spec pause_vps(binary()) :: {:ok, dispatch()} | {:error, refusal()}
  def pause_vps(vps_id), do: dispatch_power(vps_id, :pause, [:active])
  @spec resume_vps(binary()) :: {:ok, dispatch()} | {:error, refusal()}
  def resume_vps(vps_id), do: dispatch_power(vps_id, :resume, [:paused])

  @doc """
  Herstart een draaiende VPS: het besturingssysteem wordt gevraagd af te sluiten
  en komt weer op.

  Alleen vanuit `:active`. Een gestopte machine "herstarten" zou betekenen dat
  de aanvrager denkt dat hij draait, en er dan stilletjes iets anders van maken
  verbergt dat.

  De status blijft `:active`. Er is geen moment waarop de VPS uit staat in de
  zin die het paneel bedoelt -- hij is niet uitgezet -- en een tussenstand
  verzinnen zou elke andere actie erop blokkeren zolang de agent niet
  terugmeldt.
  """
  @spec reboot_vps(binary()) :: {:ok, dispatch()} | {:error, refusal()}
  def reboot_vps(vps_id), do: dispatch_power(vps_id, :reboot, [:active])

  defp dispatch_power(vps_id, kind, allowed) do
    case Repo.get(Vps, vps_id) do
      nil ->
        {:error, :not_found}

      %Vps{node_id: nil} ->
        {:error, :not_provisioned}

      %Vps{provider_vm_id: nil} ->
        {:error, :not_provisioned}

      %Vps{} = vps ->
        power_if_allowed(vps, kind, allowed)
    end
  end

  defp power_if_allowed(%Vps{status: status} = vps, kind, allowed) do
    if status in allowed,
      do: enqueue_power_command(vps, kind),
      else: {:error, {:invalid_status, status}}
  end

  defp enqueue_power_command(vps, kind) do
    # An identical power command is already queued/delivered (e.g. a
    # double-clicked Stop) — don't enqueue a duplicate. Idempotent no-op.
    if in_flight?(vps.id, kind) do
      {:ok, %{vps: vps, command: nil}}
    else
      multi =
        Multi.insert(Multi.new(), :command, fn _ ->
          Command.changeset(%Command{}, %{
            node_id: vps.node_id,
            vps_id: vps.id,
            kind: kind,
            status: :pending,
            payload: %{"vm_id" => vps.provider_vm_id}
          })
        end)

      case Repo.transaction(multi) do
        {:ok, %{command: command}} ->
          Events.broadcast_changed(:vps)
          {:ok, %{vps: vps, command: command}}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Lists the commands that should be (re)delivered to `node` now, oldest first.

  A command is deliverable when it is either:

    * still `:pending` (never handed out), or
    * `:delivered` but stale — its `delivered_at` is older than the redelivery
      TTL (#{@redelivery_ttl_seconds}s), meaning the agent likely crashed before
      reporting a result.

  Terminal commands (`:done` / `:failed`) are never returned. Redelivery relies
  on the agent being idempotent (handled on the Go side): re-issuing a
  provision/delete for an already-processed VM must be a safe no-op that
  re-reports the original outcome.
  """
  @spec deliverable_commands_for_node(Node.t()) :: [Command.t()]
  def deliverable_commands_for_node(%Node{id: node_id}) do
    cutoff = Clock.shift(-@redelivery_ttl_seconds)

    Repo.all(
      from c in Command,
        where:
          c.node_id == ^node_id and
            c.delivery_count < ^@max_afleveringen and
            (c.status == :pending or
               (c.status == :delivered and not is_nil(c.delivered_at) and
                  c.delivered_at < ^cutoff)),
        order_by: [asc: c.inserted_at]
    )
  end

  @doc """
  De commando's die vastzitten in herlevering: vaak genoeg uitgedeeld en nog
  steeds zonder resultaat.

  Deze worden niet meer aan een node gegeven. Dat is het halve antwoord; het
  andere halve is dat iemand ze te zien krijgt, want een commando dat stil uit
  de omloop verdwijnt is erger dan een dat eeuwig rondgaat -- dan staat er een
  VPS in "aanmaken" waar nooit meer iets mee gebeurt.
  """
  @spec vastgelopen_commandos() :: [Command.t()]
  def vastgelopen_commandos do
    Repo.all(
      from c in Command,
        where: c.status == :delivered and c.delivery_count >= ^@max_afleveringen,
        order_by: [asc: c.inserted_at],
        preload: [:vps]
    )
  end

  @doc """
  Marks a command as `:delivered`, stamping `delivered_at` with the current time.

  Re-delivering an already-`:delivered` command simply refreshes `delivered_at`,
  resetting its redelivery window.
  """
  @spec mark_delivered(Command.t()) :: {:ok, Command.t()} | {:error, Ecto.Changeset.t()}
  def mark_delivered(%Command{} = command) do
    command
    |> Command.changeset(%{status: :delivered, delivered_at: Clock.now()})
    |> Repo.update()
  end

  @doc """
  Marks a whole batch of commands `:delivered` in a single UPDATE. Same effect as
  calling `mark_delivered/1` per command (including resetting `delivered_at` for a
  redelivery) but without the N+1. Returns `{count, nil}`.
  """
  @spec mark_delivered_all([Command.t()]) :: {non_neg_integer(), nil}
  def mark_delivered_all([]), do: {0, nil}

  def mark_delivered_all(commands) do
    ids = Enum.map(commands, & &1.id)
    ts = Clock.now()

    # Guard on non-terminal status: a concurrent apply_result / cancel_and_release
    # may have moved a command to :done/:failed between the poll's read and this
    # write. Without the guard we'd resurrect a cancelled command back to
    # :delivered and hand the agent a provision/delete it must not run (orphan VM,
    # double-booked capacity).
    Repo.update_all(
      from(c in Command, where: c.id in ^ids and c.status in [:pending, :delivered]),
      set: [status: :delivered, delivered_at: ts, updated_at: ts],
      inc: [delivery_count: 1]
    )
  end

  @doc """
  Hoe vaak een commando opnieuw uitgedeeld mag worden voordat er iemand moet
  kijken.

  Eén aflevering is normaal. Twee of drie hoort bij een agent die opnieuw
  opstartte voordat hij zijn resultaat kwijt kon. Daarboven gaat er iets anders
  mis: niet het werk maar het terugmelden. Dan blijft dit zich elke
  #{@redelivery_ttl_seconds} seconden herhalen terwijl de VPS bij de klant in
  "aanmaken" staat en op de node allang draait.
  """
  def max_afleveringen, do: @max_afleveringen

  @doc """
  Applies an agent-reported command result.

  Delegated to `ControlPlane.Provisioning.Results`, which is where converging the
  world to match what a node said now lives. Kept here because every caller — the
  command controller, the tests — knows this module as the way in.
  """
  defdelegate apply_result(command, result), to: ControlPlane.Provisioning.Results

  defp vps_changeset(attrs) do
    Vps.changeset(%Vps{}, %{
      name: field(attrs, :name),
      region_id: field(attrs, :region_id),
      vcpu: field(attrs, :vcpu),
      ram_mb: field(attrs, :ram_mb),
      disk_gb: field(attrs, :disk_gb),
      owner_email: field(attrs, :owner_email),
      owner_id: field(attrs, :owner_id),
      ip_address: field(attrs, :ip_address),
      # Welk pakket er besteld is. Stond hier niet, en dat was niet zichtbaar:
      # de controller zet `package_id` keurig in de attrs, deze lijst liet hem
      # vallen, en een veld dat hier ontbreekt verdwijnt zonder foutmelding.
      #
      # Twee dingen hingen eraan. Het dashboard toonde elke VPS als "Onbekend
      # pakket" zonder prijs -- de eerlijke terugval voor "de server weet het
      # niet", alleen wist de server het wél. En `snelheid_van_pakket/1` leest
      # dit veld: die gaf dus altijd nil, waardoor er nooit een `rate_mbit` in
      # een provision-opdracht stond en de bandbreedtelimiet nooit is toegepast.
      package_id: field(attrs, :package_id),
      # Het moment waarop de besteller om onmiddellijke levering vroeg. Hoort bij
      # de VPS en niet bij het verzoek: de bewijslast dat die bevestiging er was
      # ligt bij ons en moet de request overleven.
      withdrawal_waiver_at: field(attrs, :withdrawal_waiver_at),
      status: :queued
    })
    |> met_eigen_consolesleutel()
  end

  # Een eigen SSH-sleutelpaar voor de webterminal, in plaats van de gedeelde
  # platformsleutel die in élke klant-VPS staat. Bewust via `put_change` en niet
  # via de cast: dit is niets wat een verzoek mag meesturen -- het is de sleutel
  # die root geeft op die machine.
  #
  # Is er geen omgevingssleutel om hem mee te versleutelen, dan gebeurt er niets
  # en valt deze VPS terug op de gedeelde sleutel. Half aanzetten zou een VPS
  # opleveren met een sleutel die niemand meer kan ontsleutelen: een console die
  # stilletjes kapot is in plaats van een console die er niet is.
  defp met_eigen_consolesleutel(changeset) do
    if Keys.enabled?() do
      {pem, publiek} = Keys.generate()

      case Keys.seal(pem) do
        {:ok, verzegeld} ->
          changeset
          |> Ecto.Changeset.put_change(:console_key_sealed, verzegeld)
          |> Ecto.Changeset.put_change(:console_key_public, publiek)

        :error ->
          changeset
      end
    else
      changeset
    end
  end

  # The exact snake_case payload the Go agent expects for a provision command.
  defp provision_payload(%Vps{} = vps, attrs, node) do
    %{
      "name" => guest_name(vps, node),
      "vcpu" => vps.vcpu,
      "ram_mb" => vps.ram_mb,
      "disk_gb" => vps.disk_gb,
      "template_id" => field(attrs, :template_id) || default_template_id(),
      "cloud_init" => field(attrs, :cloud_init) || %{},
      "ssh_keys" => (field(attrs, :ssh_keys) || []) ++ console_keys_voor(vps),
      "ip_config" => field(attrs, :ip_config),
      "rate_mbit" => snelheid_van_pakket(vps)
    }
  end

  # De snelheid die bij het pakket hoort, in megabit per seconde. De agent zet
  # hem op de netwerkkaart van de gast; dat is een bovengrens die de hypervisor
  # afdwingt, geen gegarandeerde doorvoer.
  #
  # `nil` als er geen pakket aan hangt (een VPS die intern is aangemaakt). De
  # agent laat de kaart dan ongemoeid: geen limiet is beter dan een verzonnen
  # limiet.
  #
  # Dit geldt alleen bij het aanmaken. Een bestaande VPS houdt wat hij heeft --
  # een draaiende machine krijgt niet ineens een rem omdat de catalogus is
  # veranderd.
  defp snelheid_van_pakket(%Vps{package_id: nil}), do: nil

  defp snelheid_van_pakket(%Vps{package_id: id}) do
    case Repo.get(Package, id) do
      %Package{bandwidth_mbit: mbit} when is_integer(mbit) and mbit > 0 -> mbit
      _ -> nil
    end
  end

  # De naam waaronder een gast op de hypervisor komt te staan.
  #
  # De agent herkent hieraan of hij een machine al heeft aangemaakt, dus het
  # unieke deel is geen opsmuk: stond daar ooit alleen de door de klant gekozen
  # naam in, dan nam de tweede klant met dezelfde naam op een node de draaiende
  # VM van de eerste over. `{id}` is daarom verplicht in een patroon, en zonder
  # patroon is het `{naam}-{id}`.
  #
  # Het is een slug van de weergavenaam plus een kort stuk van de UUID: leesbaar
  # voor een mens, uniek per VPS, en bij elke herhaling van hetzelfde commando
  # dezelfde naam -- dat laatste is precies wat de agent nodig heeft om een
  # opnieuw afgeleverd provision-commando als "die heb ik al" te herkennen.
  defp guest_name(%Vps{} = vps, %{guest_name_pattern: patroon} = node) when is_binary(patroon) do
    kort = short_vps_id(vps)

    patroon
    |> String.replace("{id}", kort)
    |> String.replace("{naam}", name_slug(vps))
    |> String.replace("{klant}", owner_slug(vps))
    |> String.replace("{node}", slug(node.name, "node"))
    |> String.trim("-")
    |> begrens_met_id(kort)
  end

  defp guest_name(%Vps{} = vps, _node_zonder_patroon), do: guest_name(vps)

  # Een hypervisor accepteert geen gastnaam langer dan 63 tekens, dus er moet
  # worden afgekapt. Maar NOOIT het unieke deel.
  #
  # Een eigenaar mag zijn eigen patroon kiezen en `{id}` is daarin verplicht,
  # maar die eis zegt niets over wat er ná het invullen overblijft: met
  # `{naam}-{klant}-{node}-{id}` en drie lange stukken valt precies het
  # achtervoegsel eraf. Wat overblijft is een naam die twee klanten kunnen
  # delen -- en de agent herkent zijn VM aan die naam. Dan neemt de tweede de
  # draaiende machine van de eerste over, wat de kritieke bevinding van juli
  # was.
  #
  # Daarom wordt er aan de voorkant geknipt en blijft het id achteraan staan.
  defp begrens_met_id(naam, _kort) when byte_size(naam) <= 63, do: naam

  defp begrens_met_id(naam, kort) do
    if String.contains?(naam, kort) do
      ruimte = 63 - String.length(kort) - 1

      voorkant =
        naam
        |> String.replace(kort, "")
        |> String.trim("-")
        |> String.slice(0, max(ruimte, 0))
        |> String.trim("-")

      if voorkant == "", do: kort, else: voorkant <> "-" <> kort
    else
      # Geen id in de naam: dat hoort niet te kunnen (de validatie eist hem),
      # maar afkappen zonder meer is hier het enige wat overblijft.
      String.slice(naam, 0, 63)
    end
  end

  defp short_vps_id(%Vps{id: id}), do: id |> String.replace("-", "") |> String.slice(0, 8)

  defp name_slug(%Vps{name: name}), do: slug(name, "vps")

  defp owner_slug(%Vps{owner_email: email}),
    do: slug(email && List.first(String.split(email, "@")), "klant")

  defp slug(nil, standaard), do: standaard

  defp slug(waarde, standaard) do
    schoon =
      waarde
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    if schoon == "", do: standaard, else: schoon
  end

  defp guest_name(%Vps{id: id, name: name}) do
    slug =
      (name || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    slug = if slug == "", do: "vps", else: slug
    short = id |> String.replace("-", "") |> String.slice(0, 8)
    "#{slug}-#{short}"
  end

  defp mark_vps_failed(%Vps{} = vps) do
    vps
    |> Vps.changeset(%{status: :failed})
    |> Repo.update()
  end

  # Directly marks a VPS :deleted (no agent command), used to clean up a :failed
  # VPS. Mirrors the success shape of `delete_vps/1` (`command: nil`, no command
  # was issued) so callers can treat both uniformly.
  # Releases a still-held reservation for a VPS that never reached a live VM,
  # restores the node's advertised capacity, cancels any outstanding provision
  # command and marks the VPS deleted — all atomically.
  defp cancel_and_release(%Vps{} = vps) do
    Multi.new()
    |> Multi.run(:vps, fn repo, _changes ->
      repo.get!(Vps, vps.id) |> Vps.changeset(%{status: :deleted}) |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      Reservations.release(repo, Reservations.held(repo, vps.id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      Reservations.restore_capacity(repo, reservation)
    end)
    |> Multi.update_all(
      :cancel_commands,
      from(c in Command,
        where:
          c.vps_id == ^vps.id and c.kind == :provision and
            c.status in [:pending, :delivered]
      ),
      set: [status: :failed]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{vps: vps}} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: nil}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp mark_vps_deleted(%Vps{} = vps) do
    case vps |> Vps.changeset(%{status: :deleted}) |> Repo.update() do
      {:ok, vps} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: nil}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
