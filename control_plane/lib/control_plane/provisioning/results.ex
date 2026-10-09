defmodule ControlPlane.Provisioning.Results do
  @moduledoc """
  What the control plane does when a node reports back.

  Every command the fleet dispatches ends here: the agent says what happened and
  this module converges the world to match — the command row, the VPS's status,
  the capacity it holds, the backup it produced. One job, twelve outcomes,
  because the outcomes genuinely differ: a provision commits a reservation, a
  delete releases one, a backup touches neither, and a restore puts a machine
  back into the state its customer had it in.

  Two properties hold across all of them.

  **Idempotent.** Results are re-delivered — the agent re-reports a result the
  control plane never received, and it does so precisely when the first report
  failed. The command row is locked `FOR UPDATE` and re-read; a command already
  terminal is a no-op, so a duplicate can never release a reservation or restore
  a node's capacity twice.

  **Transactional.** The command update and everything it implies commit
  together. A VPS marked `:deleted` whose reservation was not released is
  capacity the fleet believes it has and does not.
  """
  import Ecto.Query

  require Logger

  alias ControlPlane.Backups
  alias ControlPlane.Clock
  alias ControlPlane.Console.HostKeys
  alias ControlPlane.Credits
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Drift
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Net
  alias ControlPlane.Provisioning.Reservations
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions
  alias Ecto.Multi

  @doc """
  Applies a result reported by a node's agent for `command`.

  The `result` map uses string keys: `"status"` (`"done"` or `"failed"`),
  `"vm_id"`, `"ip"` and `"error"`.

  In a single transaction:

    * the command is moved to `:done` / `:failed` and the raw `result` is stored, and
    * for a provision command, the VPS is moved to `:active` (recording `vm_id`/`ip`)
      and its held reservation `:committed` on success; on failure the VPS is moved
      to `:failed` and its held reservation `:released`, returning the freed capacity
      to the node, and
    * for a delete command, on success the VPS is moved to `:deleted` and its
      committed reservation `:released`, returning capacity to the node; on failure
      the VPS and reservation are left untouched (the VM may still exist) and the
      error is recorded on the command and logged for retry.

  This is IDEMPOTENT: results may be re-delivered or retried (see
  `deliverable_commands_for_node/1`). The command row is locked `FOR UPDATE` and
  re-read; if it is already terminal (`:done`/`:failed`) the call is a no-op, so a
  duplicate result can never release a reservation or restore node capacity twice.
  The lock also serializes concurrent applications of the same command.

  Returns `{:ok, command}` with the (already- or newly-)applied command.
  """
  def apply_result(%Command{} = command, %{"status" => status} = result) do
    outcome = if status == "done", do: :done, else: :failed

    multi =
      Multi.new()
      # Lock + re-read the command. Abort (idempotent no-op) if it's already
      # terminal; this serializes concurrent/duplicate result deliveries.
      |> Multi.run(:lock, fn repo, _changes ->
        locked = repo.one!(from c in Command, where: c.id == ^command.id, lock: "FOR UPDATE")

        if locked.status in [:done, :failed],
          do: {:error, :already_applied},
          else: {:ok, locked}
      end)
      |> Multi.update(:command, fn %{lock: locked} ->
        Command.changeset(locked, %{
          status: outcome,
          result: result,
          payload: scrub_secrets(locked.payload)
        })
      end)
      |> finalize_vps(command, outcome, result)

    case Repo.transaction(multi) do
      {:ok, %{command: command}} ->
        Events.broadcast_changed(:vps)
        {:ok, command}

      # The result was already applied by a prior (or concurrent) delivery.
      {:error, :lock, :already_applied, _changes} ->
        ruim_late_vm_op(command, outcome, result)
        {:ok, command}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # --- internal helpers -----------------------------------------------------

  # Een provision die al als mislukt is afgeschreven, en dan tóch "klaar" meldt.
  #
  # Dat gebeurt: de node was een half uur onbereikbaar, de sweeper schreef de
  # uitrol af, gaf het geld terug en gaf het IP-adres vrij -- en de agent, die de
  # hele tijd gewoon doorwerkte, meldt daarna dat de VM draait. Dat resultaat
  # werd als "al verwerkt" weggegooid. De VM bleef draaien op een adres dat
  # inmiddels aan een ander kon zijn gegeven, en niemand ruimde hem op.
  #
  # Hier wordt hij alsnog afgebroken. Eén keer: een tweede late melding vindt
  # het commando dat er al staat.
  defp ruim_late_vm_op(%Command{kind: :provision} = command, :done, result) do
    case sane_vm_id(result["vm_id"]) do
      nil -> :ok
      vm_id -> Repo.transaction(fn -> plan_late_afbraak(command.id, vm_id) end)
    end

    :ok
  end

  defp ruim_late_vm_op(_command, _outcome, _result), do: :ok

  defp plan_late_afbraak(command_id, vm_id) do
    locked = Repo.one!(from c in Command, where: c.id == ^command_id, lock: "FOR UPDATE")

    if locked.status == :failed and not afbraak_gepland?(locked.node_id, vm_id) do
      %Command{}
      |> Command.changeset(%{
        node_id: locked.node_id,
        vps_id: locked.vps_id,
        kind: :delete,
        status: :pending,
        payload: %{"vm_id" => vm_id}
      })
      |> Repo.insert!()

      Logger.error(
        "provision #{locked.id} meldde klaar met vm #{vm_id} nadat hij als mislukt " <>
          "was afgeschreven; de VM wordt afgebroken"
      )
    end
  end

  defp afbraak_gepland?(node_id, vm_id) do
    Repo.exists?(
      from c in Command,
        where:
          c.node_id == ^node_id and c.kind == :delete and
            fragment("?->>'vm_id'", c.payload) == ^vm_id
    )
  end

  # A provision payload can carry a cloud-init password, which the node needs
  # while it builds the guest and nobody needs afterwards. Commands are durable
  # rows: without this the secret would sit in the database for the life of the
  # platform, in plaintext, long after the VPS it belonged to was deleted. It is
  # scrubbed the moment the command reaches a terminal state.
  @secret_payload_keys ~w(password)

  defp scrub_secrets(%{} = payload) do
    case payload["cloud_init"] do
      %{} = cloud_init ->
        Map.put(payload, "cloud_init", Map.drop(cloud_init, @secret_payload_keys))

      _ ->
        payload
    end
  end

  defp scrub_secrets(payload), do: payload

  # Provision succeeded: activate the VPS (recording provider id / ip) and commit
  # the held reservation. Capacity stays decremented.
  defp finalize_vps(multi, %Command{kind: :provision, vps_id: vps_id}, :done, result)
       when not is_nil(vps_id) do
    vm_id = sane_vm_id(result["vm_id"])

    multi
    |> Multi.run(:vps, fn repo, _changes ->
      settle_provisioned_vps(repo, vps_id, vm_id, result["ip"])
    end)
    |> Multi.run(:reservation, fn repo, %{vps: vps} ->
      commit_or_free_reservation(repo, vps_id, vps)
    end)
    |> Multi.run(:compensate, fn repo, %{vps: vps} ->
      compensate_deferred_teardown(repo, vps_id, vps, vm_id)
    end)
  end

  # Provision failed: mark the VPS failed and release its held reservation, adding
  # the freed capacity back to the node.
  defp finalize_vps(multi, %Command{kind: :provision, vps_id: vps_id} = command, :failed, result)
       when not is_nil(vps_id) do
    multi
    |> Multi.run(:vps, fn repo, _changes ->
      # FOR UPDATE: apply_result and a concurrent delete_vps both transition this
      # row; locking it here serialises them so a provision-done can't overwrite a
      # just-committed :deleting/:deleted (TOCTOU → free-running / orphaned VM).
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      vps
      |> Vps.changeset(%{status: :failed})
      |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      Reservations.release(repo, Reservations.held(repo, vps_id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      Reservations.restore_capacity(repo, reservation)
    end)
    # A provision the customer already paid for at create just died. Refund the
    # subscription's monthly price and cancel it so recurring billing never charges
    # for a VM that never existed. Idempotent: refund/cancel run once, since the
    # subscription is only :cancelled here.
    |> Multi.run(:refund, fn repo, _changes -> refund_failed_provision(repo, vps_id) end)
    # A failed provision may have left a half-created VM on the operator's node
    # (the agent returns its id precisely so we can reconcile it). Enqueue a
    # compensating :delete so the orphan is destroyed rather than lingering and
    # silently consuming the operator's real capacity forever.
    |> maybe_cleanup_orphan(vps_id, sane_vm_id(result["vm_id"]))
    |> maybe_close_node(command, result)
  end

  # Delete succeeded: the VM is gone, so mark the VPS :deleted, release its
  # committed reservation and add the reclaimed capacity back to the node.
  defp finalize_vps(multi, %Command{kind: :delete, vps_id: vps_id}, :done, _result)
       when not is_nil(vps_id) do
    multi
    |> Multi.run(:vps, fn repo, _changes ->
      # FOR UPDATE: apply_result and a concurrent delete_vps both transition this
      # row; locking it here serialises them so a provision-done can't overwrite a
      # just-committed :deleting/:deleted (TOCTOU → free-running / orphaned VM).
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      vps
      |> Vps.changeset(%{status: :deleted})
      |> repo.update()
    end)
    |> Multi.run(:reservation, fn repo, _changes ->
      Reservations.release(repo, Reservations.committed(repo, vps_id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      Reservations.restore_capacity(repo, reservation)
    end)
  end

  # Delete failed: do NOT touch the VPS or its reservation — the VM may still
  # exist, so freeing capacity would risk a double-booking. We only record the
  # error on the command (done by the caller) and log for an operator to retry.
  defp finalize_vps(multi, %Command{kind: :delete, vps_id: vps_id}, :failed, result)
       when not is_nil(vps_id) do
    # Left :deleting with its VM still there — which is the truth, and which the
    # reconciler now acts on: retry_stuck_deletes/2 re-dispatches on a widening
    # interval rather than leaving the row to sit there hoping someone clicks
    # delete a second time.
    Logger.error(
      "delete command failed for vps #{vps_id}: #{inspect(result["error"])}; " <>
        "the teardown will be retried"
    )

    multi
  end

  # Power command succeeded: transition the VPS to the resulting power state.
  # Only a live VPS is transitioned (a delete that raced in must never be
  # resurrected); capacity is untouched because power state != capacity.
  defp finalize_vps(multi, %Command{kind: kind, vps_id: vps_id}, :done, _result)
       when kind in [:start, :stop, :pause, :resume, :reboot] and not is_nil(vps_id) do
    target =
      case kind do
        :start -> :active
        :resume -> :active
        # Een herstart eindigt waar hij begon: de machine draait weer.
        :reboot -> :active
        :stop -> :stopped
        :pause -> :paused
      end

    Multi.run(multi, :vps, fn repo, _changes -> apply_power_state(repo, vps_id, target) end)
  end

  # Power command failed: leave the VPS as-is; the error is recorded on the
  # command by the caller. Log for visibility.
  defp finalize_vps(multi, %Command{kind: kind, vps_id: vps_id}, :failed, result)
       when kind in [:start, :stop, :pause, :resume, :reboot] and not is_nil(vps_id) do
    Logger.error("#{kind} command failed for vps #{vps_id}: #{inspect(result["error"])}")
    multi
  end

  # A backup acts on archives beside the VPS, never on the VPS itself, so it
  # finalises into `vps_backups` and leaves the machine's status alone — a failed
  # backup must not make a running VPS look broken.
  defp finalize_vps(multi, %Command{kind: :backup, payload: payload}, _outcome, result) do
    case payload["backup_id"] do
      id when is_binary(id) ->
        Multi.run(multi, :backup, fn _repo, _changes ->
          Backups.record_result(id, result)
        end)

      _ ->
        multi
    end
  end

  defp finalize_vps(multi, %Command{kind: :delete_backup, payload: payload}, :done, _result) do
    case payload["backup_id"] do
      id when is_binary(id) ->
        Multi.run(multi, :backup, fn _repo, _changes ->
          Backups.forget(id)
        end)

      _ ->
        multi
    end
  end

  defp finalize_vps(multi, %Command{kind: :delete_backup, payload: payload}, :failed, result) do
    # The archive is still there and still taking up the node's disk. Keep the
    # row: it is the only handle on a file that now needs a person.
    Logger.error(
      "backup deletion failed for #{inspect(payload["volid"])}: #{inspect(result["error"])}"
    )

    multi
  end

  # A restore overwrote the guest's disk. Put the VPS back into the state the
  # customer had it in — running if it was running — and out of :restoring, which
  # has been blocking everything else on this machine.
  defp finalize_vps(multi, %Command{kind: :restore_backup, vps_id: vps_id, payload: p}, :done, _r)
       when not is_nil(vps_id) do
    target = if p["start_after"], do: :active, else: :stopped

    Multi.run(multi, :vps, fn repo, _changes -> land_restored_vps(repo, vps_id, target) end)
  end

  defp finalize_vps(multi, %Command{kind: :restore_backup, vps_id: vps_id}, :failed, result)
       when not is_nil(vps_id) do
    Logger.error("restore failed for vps #{vps_id}: #{inspect(result["error"])}")

    # Out of :restoring either way: leaving it there would block the customer
    # from touching their own machine forever over a failure that already
    # happened. :stopped, not :active — after a failed qmrestore the disk may be
    # half-written, and starting it automatically is the wrong default.
    Multi.run(multi, :vps, fn repo, _changes ->
      vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

      if vps.status == :restoring,
        do: vps |> Vps.changeset(%{status: :stopped}) |> repo.update(),
        else: {:ok, vps}
    end)
  end

  # Non-provision/non-delete commands (or those without an associated VPS) only
  # update the command itself.
  # Een inventarisatie verandert geen enkele rij; hij vergelijkt alleen. Daarom
  # buiten de Multi: de vergelijking leest en meldt, en een mail versturen hoort
  # niet in een databasetransactie thuis.
  defp finalize_vps(multi, %Command{kind: :inventory, node_id: node_id}, :done, result)
       when not is_nil(node_id) do
    case gasten_uit(result) do
      nil ->
        # Een antwoord dat geslaagd heet maar geen gastenlijst bevat. Dat is
        # geen node zonder gasten: het is een antwoord waar we niets aan hebben,
        # en vergelijken zou elke VPS op die node als verdwenen aanmerken.
        #
        # Dit is precies wat er de eerste keer gebeurde: het veld stond niet in
        # de allow-list van de resultaatverwerking, werd stil weggegooid, en de
        # driftmelding sloeg alarm over twee VPS'en die gewoon draaiden.
        Logger.warning(
          "inventarisatie van node #{node_id} kwam terug zonder gastenlijst; " <>
            "de administratie is niet vergeleken"
        )

        multi

      guests ->
        Multi.run(multi, :drift, fn _repo, _changes ->
          {:ok, Drift.compare(node_id, guests)}
        end)
    end
  end

  defp finalize_vps(multi, %Command{kind: :inventory, node_id: node_id}, :failed, result) do
    # Geen vergelijking op een mislukte inventarisatie. "Ik kan even niet kijken"
    # is geen "alles is weg", en dat verschil is hier het hele punt.
    Logger.warning(
      "inventarisatie van node #{node_id} mislukte: #{inspect(result["error"])}; " <>
        "de administratie is niet vergeleken"
    )

    multi
  end

  defp finalize_vps(multi, _command, _outcome, _result), do: multi

  # De agent stuurt een lijst strings. Alles wat daar niet op lijkt is geen lege
  # lijst maar een onbruikbaar antwoord, en dan is vergelijken gevaarlijker dan
  # niets doen -- vandaar `nil` en niet `[]`.
  defp gasten_uit(%{"guests" => guests}) when is_list(guests) do
    Enum.filter(guests, &is_binary/1)
  end

  defp gasten_uit(_result), do: nil

  # The VPS row after a successful provision. Three outcomes, because a delete can
  # have been requested while the provision was still in flight.
  defp settle_provisioned_vps(repo, vps_id, vm_id, reported_ip) do
    # FOR UPDATE: apply_result and a concurrent delete_vps both transition this
    # row; locking it here serialises them so a provision-done can't overwrite a
    # just-committed :deleting/:deleted (TOCTOU → free-running / orphaned VM).
    vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

    cond do
      # A delete was requested while this provision was in flight (deferred
      # teardown): the VM now exists, so record its id and stay :deleting — the
      # compensating :delete tears it down. Never activate a VPS the customer
      # already deleted.
      vps.status in [:deleting, :deleted] and is_binary(vm_id) ->
        vps |> Vps.changeset(%{provider_vm_id: vm_id}) |> repo.update()

      # Delete requested but the provision produced no usable VM id → nothing to
      # tear down, so finish the delete now.
      vps.status in [:deleting, :deleted] ->
        vps |> Vps.changeset(%{status: :deleted}) |> repo.update()

      # Normal path: activate. The browser console SSHes to exactly
      # vps.ip_address, so this MUST stay the CP-allocated address (see
      # console_ip/3) — never one the untrusted agent reports.
      true ->
        ip = console_ip(reported_ip, vps, repo)

        vps
        |> Vps.changeset(%{status: :active, provider_vm_id: vm_id, ip_address: ip})
        |> repo.update()
    end
  end

  # A provision holds a reservation until the node confirms. What happens to it
  # depends on where settle_provisioned_vps/4 just left the VPS.
  defp commit_or_free_reservation(repo, vps_id, %Vps{status: :deleted}) do
    # No VM was created and the customer deleted it → free capacity now.
    case Reservations.held(repo, vps_id) do
      nil ->
        {:ok, nil}

      held ->
        with {:ok, _} <- Reservations.release(repo, held),
             do: Reservations.restore_capacity(repo, held)
    end
  end

  defp commit_or_free_reservation(repo, vps_id, %Vps{}) do
    case Reservations.held(repo, vps_id) do
      nil ->
        Logger.warning("provision done for vps #{vps_id}: no held reservation to commit")
        {:ok, nil}

      held ->
        # Active, or :deleting-with-a-VM: commit the booking. For the latter the
        # committed reservation is what the delete-done path releases, so capacity
        # is freed exactly once — on confirmed teardown.
        held |> Reservation.changeset(%{status: :committed}) |> repo.update()
    end
  end

  # A VPS left in :deleting by a provision that succeeded too late still has a
  # real VM behind it. Queue the teardown the customer already asked for.
  defp compensate_deferred_teardown(repo, vps_id, %Vps{status: :deleting} = vps, vm_id)
       when is_binary(vm_id) do
    %Command{}
    |> Command.changeset(%{
      node_id: vps.node_id,
      vps_id: vps_id,
      kind: :delete,
      status: :pending,
      payload: %{"vm_id" => vm_id}
    })
    |> repo.insert()
  end

  defp compensate_deferred_teardown(_repo, _vps_id, %Vps{}, _vm_id), do: {:ok, nil}

  # Power commands only move a VPS between the three states a running machine can
  # be in. Anything else (a delete that raced the power command) wins.
  defp apply_power_state(repo, vps_id, target) do
    # FOR UPDATE: apply_result and a concurrent delete_vps both transition this
    # row; locking it here serialises them so a provision-done can't overwrite a
    # just-committed :deleting/:deleted (TOCTOU → free-running / orphaned VM).
    vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

    if vps.status in [:active, :stopped, :paused],
      do: repo.update(status_changeset(vps, target)),
      else: {:ok, vps}
  end

  # A VPS entering :active starts a fresh metering interval. The meter runs only
  # on :active VPSes and charges `now - last_metered_at`, so without resetting the
  # watermark the first tick after a resume or a restore would span the entire
  # downtime — over-charging the customer and over-paying the operator for time
  # the VM never served.
  defp status_changeset(vps, :active) do
    now = Clock.now()

    vps
    |> Vps.changeset(%{status: :active})
    |> Ecto.Changeset.put_change(:last_metered_at, now)
  end

  defp status_changeset(vps, status), do: Vps.changeset(vps, %{status: status})

  defp land_restored_vps(repo, vps_id, target) do
    vps = repo.one!(from(v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE"))

    if vps.status == :restoring do
      # The disk is older, so the guest's SSH host key is older too. TOFU would
      # read that as exactly the attack it exists to catch and refuse the console
      # — locking the customer out of the thing they would use to check the
      # restore worked. Forget the pin; the next connection pins afresh.
      HostKeys.forget(vps.id)

      repo.update(status_changeset(vps, target))
    else
      # Something else moved it — a delete that raced the restore. Leave it be.
      {:ok, vps}
    end
  end

  # Een ontbrekende template is geen incident maar een toestand: hij is er niet,
  # dus de volgende bestelling op deze node faalt precies zo, en de daarna ook.
  # Zolang de node openstaat kiest de scheduler hem juist het liefst -- hij heeft
  # immers de meeste vrije ruimte, want er staat niets op. Daarom sluit een
  # mislukking hierop de node af in plaats van hem te laten herhalen.
  #
  # Alleen bij dit soort fout. Een netwerkhapering of een volle schijf is wel een
  # incident, en een node daarvoor dichtzetten zou een tijdelijke storing tot een
  # blijvende maken.
  @template_failure ~r/(clone template|template .* not found|template is required|esxi: template)/i

  defp maybe_close_node(multi, %Command{node_id: node_id}, result) when not is_nil(node_id) do
    reden = result["error"]

    if is_binary(reden) and Regex.match?(@template_failure, reden) do
      Multi.run(multi, :close_node, fn _repo, _changes -> close_node(node_id, reden) end)
    else
      multi
    end
  end

  defp maybe_close_node(multi, _command, _result), do: multi

  defp close_node(node_id, reden) do
    Logger.warning("node #{node_id} afgesloten na een mislukte bestelling: #{kort(reden)}")

    case Fleet.drain_node(node_id, kort(reden)) do
      {:ok, node} ->
        {:ok, node}

      # Een node die intussen is verwijderd of al dicht staat mag deze transactie
      # niet terugdraaien: de VPS is nog steeds mislukt en dat moet hoe dan ook
      # worden vastgelegd.
      {:error, _reden} ->
        {:ok, :niet_afgesloten}
    end
  end

  # De kolom is begrensd en het paneel toont hem op een kaart; de eerste regel
  # zegt wat er mis is, de rest staat in Activiteit.
  defp kort(reden), do: reden |> String.trim() |> String.slice(0, 200)

  defp maybe_cleanup_orphan(multi, _vps_id, nil), do: multi

  defp maybe_cleanup_orphan(multi, vps_id, vm_id) do
    Multi.insert(multi, :orphan_cleanup, fn %{vps: vps} ->
      Command.changeset(%Command{}, %{
        node_id: vps.node_id,
        vps_id: vps_id,
        kind: :delete,
        status: :pending,
        payload: %{"vm_id" => vm_id}
      })
    end)
  end

  # Resolve the console target IP for a provision-done result.
  #
  # The control plane allocates the VPS IP itself (IpPool) and injects it via
  # cloud-init, so vps.ip_address is authoritative and we keep it — a differing
  # agent report is logged (possible operator misconfig or an attempt to redirect
  # the shared-key console at a co-tenant) but NOT applied.
  defp console_ip(reported, %Vps{ip_address: allocated} = vps, _repo)
       when is_binary(allocated) and allocated != "" do
    if is_binary(reported) and reported != "" and reported != allocated do
      Logger.warning(
        "vps #{vps.id}: agent-reported ip #{inspect(reported)} differs from CP-allocated #{allocated}; keeping allocated (console binds to the CP-assigned address)"
      )
    end

    allocated
  end

  # No CP-allocated IP (e.g. the node advertises no pool): only adopt the reported
  # IP if it is a valid IPv4 that falls inside the node's DECLARED range. Unlike
  # before there is NO accept-anything fallback — an unbounded node yields no IP
  # rather than trusting an arbitrary operator-supplied address.
  defp console_ip(reported, %Vps{} = vps, repo) when is_binary(reported) and reported != "" do
    node = vps.node_id && repo.get(Node, vps.node_id)

    if Net.valid?(reported) and ip_in_declared_range?(reported, node) do
      reported
    else
      Logger.warning(
        "vps #{vps.id}: no CP-allocated ip and reported #{inspect(reported)} is not inside a declared node range; leaving ip unset"
      )

      nil
    end
  end

  defp console_ip(_reported, %Vps{ip_address: allocated}, _repo), do: allocated

  # Strict range check: a node WITHOUT a valid declared [start,end] range accepts
  # nothing (returns false), closing the old accept-any hole.
  defp ip_in_declared_range?(ip, %Node{vps_range_start: s, vps_range_end: e})
       when is_binary(s) and is_binary(e) do
    Net.valid?(s) and Net.valid?(e) and Net.valid?(ip) and
      Net.to_int(ip) >= Net.to_int(s) and
      Net.to_int(ip) <= Net.to_int(e)
  end

  defp ip_in_declared_range?(_ip, _node), do: false

  # Pull the IPv4 out of a Proxmox-style ip_config ("ip=10.0.0.5/24,gw=..."), so
  # an explicit-config VPS still gets an authoritative ip_address.

  # Bound the agent-supplied VM id to a sane length/charset so it can't smuggle
  # control characters or absurd values into the DB / later command payloads.
  defp sane_vm_id(v) when is_binary(v) do
    if v != "" and String.length(v) <= 64 and String.match?(v, ~r/\A[A-Za-z0-9._:-]+\z/),
      do: v,
      else: nil
  end

  defp sane_vm_id(_), do: nil

  # Geld terug voor een uitrol die is mislukt, plus het abonnement opzeggen zodat
  # er nooit maandelijks wordt afgeschreven voor een machine die niet bestaat.
  #
  # Het bedrag komt uit de grootboekregel en niet uit de prijs van het pakket of
  # van het abonnement. Dat is het enige getal dat zeker klopt: het is wat er
  # daadwerkelijk is afgeschreven. Stond het pakket er inmiddels anders bij, of
  # kreeg de klant korting, dan wijken die andere twee af -- naar boven of naar
  # beneden, en allebei is fout.
  #
  # `refund_charge_for_vps/1` markeert bovendien de oorspronkelijke afschrijving
  # als teruggeboekt. Dat deed dit pad niet, en daardoor bleef er een openstaande
  # `vps_charge` staan die de weessweep later opnieuw zou kunnen terugboeken. Dat
  # ging vandaag goed omdat die sweep op iets anders filtert -- geluk, geen
  # ontwerp, en precies het soort verschil waar geld tussendoor valt.
  #
  # Geen afschrijving gevonden? Dan is er niets afgeschreven en hoort er niets
  # terug. Hier de abonnementsprijs terugbetalen zou geld geven dat nooit is
  # betaald.
  defp refund_failed_provision(_repo, vps_id) do
    terugbetaald = Credits.refund_charge_for_vps(vps_id)
    {:ok, _} = Subscriptions.cancel_for_vps(vps_id)

    if terugbetaald, do: {:ok, :refunded}, else: {:ok, :no_charge}
  end

  # Reservation lookups are intentionally non-bang (Repo.one, not Repo.one!).
  # A finalisation can legitimately find no matching reservation — the reconciler
  # may have already reclaimed a stale `:held` one, or a prior delivery already
  # released it. Raising here would fail the whole `apply_result/2` transaction,
  # the command would never reach a terminal state, and the agent would redeliver
  # the result forever. Returning nil lets the caller skip the release/restore and
  # still mark the command done. Run inside the locked txn via the passed `repo`.
end
