defmodule ControlPlane.Backups do
  @moduledoc """
  Scheduled backups of customer VPS disks.

  ## What this covers, and what it does not

  These are node-local `vzdump` archives: the node writes them to its own
  storage. That protects against the common failure — a customer broke their own
  machine and wants yesterday back — and not against the rare one, a node losing
  the disk that holds both the VPS and its backups. Both halves are worth
  saying out loud, because "we back up your VPS" means different things to a
  customer and to whoever has to honour it.

  The control plane never holds the bytes. It records that an archive exists and
  where, decides when the next one is due, and prunes the oldest past the
  retention count. Everything physical happens on the node.

  ## Why a command rather than a request

  A backup is dispatched the same way provisioning is: a `:backup` command on the
  node's poll. It can take minutes, it can fail halfway, and the node may be
  asleep when it is due — all of which the command pipeline already handles, and
  none of which an HTTP call would.
  """
  import Ecto.Query

  require Logger

  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo
  alias Ecto.Multi

  @doc "How often each VPS is backed up, unless configured otherwise."
  def interval_seconds, do: Application.get_env(:control_plane, :backup_interval_seconds, 86_400)

  @doc """
  How many archives to keep per VPS.

  Deliberately small: these sit on the node's own disk next to the VPSes they
  protect, so retention is bounded by the storage a node can spare, not by what
  would be nice to have.
  """
  def keep, do: Application.get_env(:control_plane, :backup_keep, 2)

  @doc """
  Dispatches a backup for every VPS that is due one, and returns a summary.

  "Due" means active, on an online node, with a recognised provider VM, and with
  no backup started within `interval_seconds`. A VPS with a backup already in
  flight is skipped rather than queued again — a second `vzdump` of the same
  guest would contend with the first for the node's disk.
  """
  def run_due(now \\ DateTime.utc_now()) do
    due = due_vpses(now)

    Enum.reduce(due, %{started: 0, errors: 0}, fn vps, acc ->
      case start_backup(vps) do
        {:ok, _} ->
          %{acc | started: acc.started + 1}

        {:error, reason} ->
          Logger.error("backup for vps #{vps.id} could not be dispatched: #{inspect(reason)}")
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  @doc """
  Queues one backup of `vps`: a row to track it and a command to do it.

  Both in one transaction, because a row with no command is a backup that never
  runs and a command with no row is one nobody can find.
  """
  def start_backup(%Vps{} = vps) do
    now = Clock.now()

    Multi.new()
    |> Multi.insert(:backup, fn _ ->
      VpsBackup.changeset(%VpsBackup{}, %{
        vps_id: vps.id,
        node_id: vps.node_id,
        status: :running,
        started_at: now
      })
    end)
    |> Multi.insert(:command, fn %{backup: backup} ->
      Command.changeset(%Command{}, %{
        node_id: vps.node_id,
        vps_id: vps.id,
        kind: :backup,
        status: :pending,
        payload: %{"vm_id" => vps.provider_vm_id, "backup_id" => backup.id}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{backup: backup}} ->
        {:ok, backup}

      # Een botsing op de unieke index betekent dat een gelijktijdig verzoek net
      # vóór ons een back-up heeft gestart. Dat is hetzelfde antwoord als wanneer
      # `loopt_er_al_een?/1` hem had gevangen -- de voorwacht is goedkoop, de
      # index is het slot.
      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        if unieke_botsing?(changeset), do: {:error, :already_running}, else: {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Hoe lang een back-up mag draaien voordat we hem als vastgelopen beschouwen.
  #
  # Een vzdump van twintig gigabyte is een kwestie van minuten; van een terabyte
  # kan het uren duren. Zes uur is ruim genoeg voor het tweede en kort genoeg om
  # niet dagen te blijven staan.
  @vastgelopen_na_uren 6

  # Hoe vers een heartbeat moet zijn voordat we een node werk geven. Ruim boven
  # het hartslaginterval van dertig seconden, zodat één gemiste tik geen ronde
  # overslaat.
  @node_levend_seconds 180

  @doc """
  Zet back-ups die blijven hangen op mislukt.

  Een back-up staat op `:running` totdat de node terugmeldt. Meldt hij nooit
  terug -- de node valt uit, het resultaat gaat verloren -- dan blijft die rij
  eeuwig staan. Op productie stond er een sinds twee dagen "bezig" in het
  dashboard van een klant.

  Sinds er één lopende back-up per VPS mag zijn, is dit niet langer alleen
  cosmetisch: zo'n blijvende rij zou elke volgende back-up van die VPS
  tegenhouden. Een vangnet dat een dienst blokkeert is erger dan geen vangnet.

  Mislukt en niet verwijderd: "de back-up van dinsdag is niet gelukt" is iets
  wat een klant hoort te kunnen zien.
  """
  @spec fail_vastgelopen(pos_integer()) :: {non_neg_integer(), nil}
  def fail_vastgelopen(uren \\ @vastgelopen_na_uren) do
    grens = Clock.shift(-uren * 3600)
    nu = Clock.now()

    Repo.update_all(
      from(b in VpsBackup,
        where: b.status == :running and not is_nil(b.started_at) and b.started_at < ^grens
      ),
      set: [
        status: :failed,
        error: "de node meldde niets terug binnen #{uren} uur",
        finished_at: nu,
        updated_at: nu
      ]
    )
  end

  defp unieke_botsing?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_veld, {_bericht, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  @doc """
  Start een back-up omdat de klant erom vraagt, buiten het schema om.

  Dit is het moment vóór iets engs: een pakketupgrade, een configuratie die hij
  zelf niet vertrouwt. Wachten tot vannacht is dan geen antwoord.

  Wat wél geweigerd wordt, en waarom:

    * een VPS die niet draait of nog niet is uitgerold -- er is niets om te
      archiveren;
    * een node die niet bereikbaar is -- het commando zou blijven liggen en de
      klant zou denken dat er een back-up was;
    * een back-up die al loopt voor deze VPS -- een tweede `vzdump` van dezelfde
      gast vecht met de eerste om de schijf van de node.

  Het schema kijkt daarnaast naar `interval_seconds`; die grens geldt hier
  bewust niet. Een handmatige back-up is een uitzondering en de klant weet zelf
  waarom hij hem nu wil.
  """
  @spec start_on_demand(Vps.t()) ::
          {:ok, VpsBackup.t()}
          | {:error, :not_provisioned | :already_running | :node_unreachable | term()}
  def start_on_demand(%Vps{} = vps) do
    vps = Repo.preload(vps, :node)

    cond do
      vps.status != :active or is_nil(vps.provider_vm_id) or is_nil(vps.node_id) ->
        {:error, :not_provisioned}

      is_nil(vps.node) or vps.node.status not in [:online, :draining] ->
        {:error, :node_unreachable}

      loopt_er_al_een?(vps) ->
        {:error, :already_running}

      true ->
        start_backup(vps)
    end
  end

  defp loopt_er_al_een?(%Vps{id: id}) do
    Repo.exists?(from b in VpsBackup, where: b.vps_id == ^id and b.status == :running)
  end

  @doc """
  Records what the node reported, and prunes anything past the retention count.

  A failure is written down rather than dropped: "the last three nightly backups
  failed" is the single most useful thing this table can tell anyone, and it can
  only tell it if failures are rows too.
  """
  def record_result(backup_id, result) do
    now = Clock.now()

    case Repo.get(VpsBackup, backup_id) do
      nil -> {:error, :not_found}
      %VpsBackup{} = backup -> save_and_prune(backup, result_attrs(result, now))
    end
  end

  defp save_and_prune(backup, attrs) do
    with {:ok, saved} <- backup |> VpsBackup.changeset(attrs) |> Repo.update() do
      if saved.status == :done, do: prune(saved.vps_id)
      {:ok, saved}
    end
  end

  # The allow-list that turns an agent's reported result into columns. Only these
  # fields are ever written; anything else the agent sends is ignored.
  defp result_attrs(%{"status" => "done"} = result, now) do
    %{
      status: :done,
      volid: result["volid"],
      size_bytes: sane_size(result["size_bytes"]),
      finished_at: now
    }
  end

  defp result_attrs(result, now) do
    %{status: :failed, error: to_string(result["error"] || "unknown"), finished_at: now}
  end

  @doc """
  Queues deletion of every archive past the newest `keep/0` for this VPS.

  The rows go when the node confirms the archive did; deleting the row first
  would lose the only handle on a file still taking up the node's disk.
  """
  def prune(vps_id) do
    stale =
      Repo.all(
        from b in VpsBackup,
          where: b.vps_id == ^vps_id and b.status == :done and not is_nil(b.volid),
          order_by: [desc: b.finished_at],
          offset: ^keep()
      )

    # One lookup, not one per stale row: vps_id does not change inside the loop.
    # A VPS that is already gone queues nothing — the node tore its archives down
    # with it, and a delete_backup command for a VPS row that no longer exists
    # cannot be finalised.
    queued =
      case Repo.get(Vps, vps_id) do
        nil -> 0
        %Vps{} -> Enum.count(stale, &queue_archive_delete(&1, vps_id))
      end

    {:ok, queued}
  end

  # True when a command was actually queued, so prune/1 reports what it did
  # rather than what it found.
  defp queue_archive_delete(%VpsBackup{node_id: nil}, _vps_id), do: false

  defp queue_archive_delete(%VpsBackup{} = backup, vps_id) do
    result =
      %Command{}
      |> Command.changeset(%{
        node_id: backup.node_id,
        vps_id: vps_id,
        kind: :delete_backup,
        status: :pending,
        payload: %{"volid" => backup.volid, "backup_id" => backup.id}
      })
      |> Repo.insert()

    match?({:ok, _}, result)
  end

  @doc "Forgets a backup the node has confirmed it deleted."
  def forget(backup_id) do
    case Repo.get(VpsBackup, backup_id) do
      nil -> {:ok, :already_gone}
      backup -> Repo.delete(backup)
    end
  end

  @doc """
  Rolls a VPS back to `backup_id`.

  Destructive and deliberately narrow: the archive must belong to this VPS, must
  have completed, and must still have a handle on a file. The VPS goes to
  `:restoring` for the duration, which blocks every other action on it —
  including a second restore, which would race the first over the same disk.

  What the customer loses is everything written since the backup was taken. The
  control plane does not take a safety copy first: that would double the time,
  can fail for space on the node, and with two archives kept it would push out
  the older restore point the customer might actually have wanted. Saying so
  plainly before the button is pressed is the honest guard, not a hidden one.
  """
  def restore(%Vps{} = vps, backup_id) do
    with %VpsBackup{} = backup <- Repo.get(VpsBackup, backup_id),
         :ok <- restorable(vps, backup) do
      Multi.new()
      |> Multi.run(:vps, fn repo, _ -> begin_restoring(repo, vps.id) end)
      |> Multi.insert(:command, fn %{vps: locked} ->
        Command.changeset(%Command{}, %{
          node_id: locked.node_id,
          vps_id: locked.id,
          kind: :restore_backup,
          status: :pending,
          payload: %{
            "vm_id" => locked.provider_vm_id,
            "volid" => backup.volid,
            # What to leave the guest as afterwards. A VPS that was running
            # before a restore should be running after it.
            "start_after" => vps.status == :active
          }
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{vps: restoring}} -> {:ok, restoring}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # FOR UPDATE, and re-check the status inside the lock: two restores dispatched
  # at once would otherwise both pass restorable/2 and both tell the node to
  # overwrite the same disk.
  defp begin_restoring(repo, vps_id) do
    locked = repo.one!(from v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE")

    if locked.status in [:active, :stopped],
      do: locked |> Vps.changeset(%{status: :restoring}) |> repo.update(),
      else: {:error, {:invalid_status, locked.status}}
  end

  defp restorable(%Vps{} = vps, %VpsBackup{} = backup) do
    cond do
      # Not found rather than forbidden: whether some other customer's backup
      # exists is none of this caller's business.
      backup.vps_id != vps.id -> {:error, :not_found}
      backup.status != :done -> {:error, :backup_not_restorable}
      is_nil(backup.volid) -> {:error, :backup_not_restorable}
      is_nil(vps.node_id) or is_nil(vps.provider_vm_id) -> {:error, :not_provisioned}
      vps.status not in [:active, :stopped] -> {:error, {:invalid_status, vps.status}}
      true -> :ok
    end
  end

  @doc "A VPS's restore points, newest first. Failures included — they are news."
  def list_for_vps(vps_id) do
    Repo.all(
      from b in VpsBackup,
        where: b.vps_id == ^vps_id,
        order_by: [desc: b.inserted_at],
        limit: 50
    )
  end

  # --- internals -------------------------------------------------------------

  defp due_vpses(now) do
    cutoff = DateTime.add(now, -interval_seconds(), :second)

    # A VPS with a backup started after the cutoff is not due; one with a backup
    # still :running is not due either, whenever it started, because a second
    # vzdump of the same guest would fight the first for the node's disk.
    recent =
      from b in VpsBackup,
        where:
          b.vps_id == parent_as(:vps).id and
            (b.started_at >= ^cutoff or b.status == :running),
        select: 1

    # De node moet niet alleen de juiste status hebben maar ook nog praten.
    #
    # `:draining` telt mee -- een node die leegloopt hoort zijn klanten gewoon te
    # blijven back-uppen -- maar een node die niet meer heartbeat haalt zijn
    # commando's niet op. Een back-up daarheen sturen levert een rij op die zes
    # uur "bezig" staat en dan mislukt, elke dag opnieuw, voor werk dat nooit is
    # begonnen. Dat de node stil is, wordt al ergens anders gemeld; daar hoeft
    # geen stroom mislukte back-ups bij.
    levend = DateTime.add(now, -@node_levend_seconds, :second)

    Repo.all(
      from v in Vps,
        as: :vps,
        join: n in assoc(v, :node),
        where:
          v.status == :active and not is_nil(v.provider_vm_id) and
            n.status in [:online, :draining] and
            not is_nil(n.last_heartbeat_at) and n.last_heartbeat_at >= ^levend,
        where: not exists(recent),
        preload: [:node]
    )
  end

  defp sane_size(n) when is_integer(n) and n >= 0, do: n

  defp sane_size(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp sane_size(_), do: nil
end
