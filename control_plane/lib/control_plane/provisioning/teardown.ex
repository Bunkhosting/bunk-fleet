defmodule ControlPlane.Provisioning.Teardown do
  @moduledoc """
  Het afbreken van een VPS, en het opnieuw proberen als dat mislukt.

  `delete_vps/1` kiest de weg die bij de toestand van de VPS past. Staat er een
  VM op een node, dan wordt het een `:delete`-commando voor de agent en komt de
  capaciteit pas vrij als die meldt dat de VM weg is. Is er nooit een VM geweest,
  dan wordt de rij direct afgesloten en de vastgehouden reservering vrijgegeven.
  Loopt de uitrol nog, dan wordt de afbraak uitgesteld tot het resultaat ervan
  binnen is.

  `retry_stuck_deletes/2` stuurt mislukte afbraken opnieuw uit, met een wachttijd
  die bij elke mislukking verdubbelt. Hij staat hier en niet bij de sweeps omdat
  hij hetzelfde commando uitstuurt als `delete_vps/1`.
  """
  import Ecto.Query
  require Logger

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Provisioning.CommandQueue
  alias ControlPlane.Provisioning.Reservations
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions
  alias Ecto.Multi

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
  @spec delete_vps(binary()) ::
          {:ok, Provisioning.dispatch() | map()} | {:error, Provisioning.refusal()}
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
    if CommandQueue.in_flight?(vps.id, :delete),
      do: {:error, :already_deleting},
      else: dispatch_delete(vps)
  end

  # If the provision command is still in flight (delivered to the agent), the
  # agent may be mid-CreateVM; force-failing it now would orphan the VM it
  # produces AND double-count the freed capacity. Defer: mark :deleting and let
  # the provision-done result run the compensating teardown. Only when nothing is
  # in flight is it safe to cancel-and-release immediately.
  defp teardown_unprovisioned(vps) do
    if CommandQueue.provision_in_flight?(vps.id),
      do: defer_teardown(vps),
      else: cancel_and_release(vps)
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

  # Directly marks a VPS :deleted (no agent command), used to clean up a :failed
  # VPS. Mirrors the success shape of `delete_vps/1` (`command: nil`, no command
  # was issued) so callers can treat both uniformly.
  defp mark_vps_deleted(%Vps{} = vps) do
    case vps |> Vps.changeset(%{status: :deleted}) |> Repo.update() do
      {:ok, vps} ->
        Events.broadcast_changed(:vps)
        {:ok, %{vps: vps, command: nil}}

      {:error, changeset} ->
        {:error, changeset}
    end
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
end
