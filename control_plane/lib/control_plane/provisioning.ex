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

  ## Lockvolgorde

  Een transactie die zowel een commando-rij als een VPS-rij vergrendelt, doet
  dat in deze volgorde: **eerst het commando, dan de VPS**. Dat is de volgorde
  van `apply_result/2` (het commando `FOR UPDATE`, daarna de VPS `FOR UPDATE`),
  en elke andere plek volgt hem. Twee transacties die dezelfde rijen in
  omgekeerde volgorde pakken kunnen op elkaar gaan wachten; Postgres breekt er
  dan één af, en dat is een afbraak of een resultaat dat verloren gaat.

  Een gewone `UPDATE` vergrendelt ook. `Teardown`'s `cancel_and_release` deed
  eerst de VPS en dan de uitrolcommando's, en vergrendelt die commando's nu
  vooraf. Wie hier een nieuwe transactie toevoegt die beide raakt: neem eerst de
  commando's, op volgorde van id, en dan de VPS.

  Het uitsturen van een bestelling vergrendelt alleen de VPS en voegt daarna
  het uitrolcommando in. Dat is geen omgekeerde volgorde: een `:queued` VPS
  heeft nog geen commando's, en het nieuwe is tot de commit voor niemand
  zichtbaar.
  """
  import Ecto.Query, warn: false

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
  alias ControlPlane.Provisioning.CommandQueue
  alias ControlPlane.Provisioning.GuestName
  alias ControlPlane.Provisioning.Power
  alias ControlPlane.Provisioning.Reservations
  alias ControlPlane.Provisioning.Sweeps
  alias ControlPlane.Provisioning.Teardown
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
          | :vps_state_changed
          | {:invalid_status, atom()}

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
  Is de VPS verwijderd voordat hij kon worden uitgestuurd, dan blijft hij
  `:deleted`, gaat er geen uitrol uit, komt de reservering vrij en is het
  antwoord `{:error, :already_deleting}`.

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

  @doc "Zie `ControlPlane.Provisioning.Sweeps.fail_stuck_queued_vpses/1`."
  defdelegate fail_stuck_queued_vpses(grace_seconds \\ 600), to: Sweeps

  # Publiek voor de test die het gat in `fail_stuck_queued_vpses/1` vastlegt.
  @doc false
  defdelegate faal_wachtende_vps(vps_id), to: Sweeps

  @doc "Zie `ControlPlane.Provisioning.Sweeps.fail_stuck_provisioning_vpses/1`."
  defdelegate fail_stuck_provisioning_vpses(grace_seconds \\ 1800), to: Sweeps

  @doc "Zie `ControlPlane.Provisioning.Sweeps.fail_stuck_restores/1`."
  defdelegate fail_stuck_restores(uren \\ 6), to: Sweeps

  @doc "Zie `ControlPlane.Provisioning.CommandQueue.purge_old_commands/2`."
  defdelegate purge_old_commands(dagen \\ 90, hoogstens \\ 5_000), to: CommandQueue

  @doc """
  Creates a VPS on behalf of an authenticated owner, enforcing the per-owner quota
  and stamping ownership from the trusted session (never the request body).

  Any `owner_id`/`owner_email` present in `attrs` is dropped and replaced with the
  caller's, so a user cannot provision a VPS into someone else's account. Returns
  `{:error, :quota_exceeded}` when the owner already holds the maximum number of
  live (non-`:deleted`/non-`:failed`) VPSes.

  `afschrijving:` is de grootboekregel waarmee de klant voor deze VPS betaalde.
  Hij wordt in dezelfde transactie als de VPS aan die VPS gekoppeld. Gebeurde
  dat erna, los, dan kon de VPS bestaan terwijl de afschrijving nog verweesd
  leek -- en dan betaalde `Credits.refund_orphan_charges/1` hem tien minuten
  later terug: een gratis VPS, en een klant die "mislukt" las en opnieuw
  bestelde.
  """
  @spec create_vps_for_owner(%{id: binary(), email: binary()}, map(), keyword()) ::
          {:ok, dispatch()} | {:error, refusal() | Ecto.Changeset.t()}
  def create_vps_for_owner(%{id: owner_id, email: email}, attrs, opts \\ []) do
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
    with {:ok, %Vps{} = vps} <- insert_within_quota(owner_id, full, opts[:afschrijving]),
         {:ok, %{vps: placed}} <- place_and_dispatch(vps, placement_request(full), full) do
      {:ok, %{vps: placed}}
    end
  end

  # The quota gate, the durable :queued insert and the subscription, in one
  # short transaction: the per-owner advisory lock (auto-released at commit)
  # serialises concurrent creates against the quota check, so two cannot both
  # pass the cap.
  #
  # Het abonnement hoort erbij. Het werd eerst pas na het plaatsen aangemaakt,
  # buiten elke transactie, en de uitkomst werd weggegooid: viel het proces
  # daartussen weg (een uitrol, een crash), dan draaide er een VPS die na de
  # eerste maand nooit meer werd gefactureerd -- en niemand die het zag. Mislukt
  # het plaatsen hierna, dan zegt place_and_dispatch het weer op.
  defp insert_within_quota(owner_id, attrs, afschrijving) do
    Repo.transaction(fn ->
      :ok = Locks.take(Repo, :owner_quota, owner_id)

      if count_live_vpses(owner_id) >= max_vpses_per_owner() do
        Repo.rollback(:quota_exceeded)
      else
        attrs
        |> insert_or_rollback()
        |> met_abonnement(owner_id, attrs)
        |> met_afschrijving(afschrijving)
      end
    end)
  end

  defp met_afschrijving(vps, nil), do: vps

  defp met_afschrijving(vps, afschrijving) do
    case Credits.attach_vps(afschrijving, vps.id) do
      {:ok, _} -> vps
      {:error, reden} -> Repo.rollback(reden)
    end
  end

  defp met_abonnement(vps, owner_id, attrs) do
    case Subscriptions.create_for_vps(vps, owner_id, field(attrs, :package_id)) do
      {:ok, _} -> vps
      {:error, reden} -> Repo.rollback(reden)
    end
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

  # Publiek maar ongedocumenteerd: een test moet dit pad kunnen aanroepen met een
  # struct die verouderd is, want precies dat is de race met een klant die de
  # VPS verwijdert terwijl hij nog `:queued` is.
  @doc false
  @spec plaats_en_verstuur(Vps.t(), map()) ::
          {:ok, dispatch()} | {:error, refusal() | Ecto.Changeset.t()}
  def plaats_en_verstuur(%Vps{} = vps, attrs),
    do: place_and_dispatch(vps, placement_request(attrs), attrs)

  defp place_and_dispatch(%Vps{} = vps, req, attrs) do
    case Scheduler.place(req, vps_id: vps.id) do
      {:ok, %{node: node}} ->
        dispatch(vps, node, attrs)

      {:error, :no_capacity} ->
        {:ok, _failed} = mark_vps_failed(vps)
        {:ok, _} = Subscriptions.cancel_for_vps(vps.id)
        # The VPS was persisted (now :failed) so the dashboard should still update.
        Events.broadcast_changed(:vps)
        {:error, :no_capacity}
    end
  end

  # IP allocation, the VPS update and the command insert run in ONE
  # transaction. Allocation takes a per-node advisory lock and the
  # `vpses_active_node_ip_uidx` unique index is the DB backstop, so two
  # concurrent creates on the same node can never share an address.
  #
  # De VPS wordt eerst opnieuw gelezen, onder slot, en alleen een VPS die nog
  # `:queued` is gaat door. Tussen de insert en dit punt ligt een commit en een
  # plaatsing: tijd genoeg voor de klant om de VPS die hij in zijn lijst ziet te
  # verwijderen. De update op de oude struct overschreef dat `:deleted` dan met
  # `:provisioning`, en er ging een uitrol uit. Het abonnement was bij het
  # verwijderen al opgezegd: een draaiende VM die nooit gefactureerd wordt.
  defp dispatch(%Vps{} = vps, %Node{} = node, attrs) do
    multi =
      Multi.new()
      |> Multi.run(:wachtend, fn repo, _changes -> nog_wachtend(repo, vps.id) end)
      |> Multi.run(:allocation, fn repo, _changes -> allocate_ip(repo, attrs, node) end)
      |> Multi.run(:vps, fn repo, %{wachtend: vers, allocation: {_attrs, ip}} ->
        vers
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

      {:error, step, reason, _changes} ->
        # Any failure here is AFTER the scheduler reserved capacity, so release
        # the held reservation and restore the node's capacity (else it leaks).
        # Ook als de VPS intussen verwijderd is: die afbraak zag nog geen node en
        # gaf dus niets vrij. IP en SSH-forward zaten in de teruggedraaide
        # transactie en bestaan niet. Een verwijderde VPS blijft `:deleted`.
        {:ok, _} = fail_and_release_reservation(vps.id)
        {:ok, _} = Subscriptions.cancel_for_vps(vps.id)
        Events.broadcast_changed(:vps)
        {:error, weigering(step, reason)}
    end
  end

  # Het slot op de VPS is hier het eerste slot, en dat keert de vaste volgorde
  # (eerst commando's, dan de VPS; zie de moduledoc) niet om: een VPS die nog
  # `:queued` is heeft geen commando's, en het uitrolcommando dat deze transactie
  # invoegt is voor niemand anders zichtbaar tot de commit. Er is dus geen
  # commandorij waarop een ander kan wachten terwijl hij deze VPS vasthoudt.
  defp nog_wachtend(repo, vps_id) do
    case repo.one(from v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE") do
      %Vps{status: :queued} = vers -> {:ok, vers}
      %Vps{status: status} -> {:error, {:niet_meer_wachtend, status}}
      nil -> {:error, {:niet_meer_wachtend, nil}}
    end
  end

  # De klant heeft zelf verwijderd; `already_deleting` zegt precies dat, en is
  # een 409 met een zin die de frontend al kent. Geen nieuwe code. Een andere
  # toestand (de sweep die een te lang wachtende VPS opgaf) is een toestand die
  # onder de bestelling veranderde.
  defp weigering(:wachtend, {:niet_meer_wachtend, :deleted}), do: :already_deleting
  defp weigering(:wachtend, {:niet_meer_wachtend, _status}), do: :vps_state_changed
  defp weigering(_step, reason), do: reason

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
  #
  # `:deleted` is een eindstation en blijft staan. Een VPS die de klant tijdens
  # het bestellen verwijderde, kwam anders als `:failed` terug in zijn lijst en
  # in de quotumtelling. De reservering wordt wél vrijgegeven als hij nog vast
  # staat: de afbraak van een VPS zonder node gaf er niets vrij. Een al
  # vrijgegeven reservering is niet meer `:held` en beweegt niet nog eens.
  #
  # Publiek maar ongedocumenteerd, voor de test die dat vastlegt.
  @doc false
  @spec fail_and_release_reservation(binary()) :: {:ok, map()} | {:error, term(), term(), map()}
  def fail_and_release_reservation(vps_id) do
    Multi.new()
    |> Multi.run(:vps, fn repo, _changes -> faal_tenzij_verwijderd(repo, vps_id) end)
    |> Multi.run(:reservation, fn repo, _changes ->
      Reservations.release(repo, Reservations.held(repo, vps_id))
    end)
    |> Multi.run(:restore_capacity, fn repo, %{reservation: reservation} ->
      Reservations.restore_capacity(repo, reservation)
    end)
    |> Repo.transaction()
  end

  # Onder slot, zodat een gelijktijdige afbraak ervoor of erna komt en niet
  # ertussen. Geen commando's vooraf: dit pad loopt alleen na een teruggedraaide
  # uitsturing, en dan bestaat er geen uitrolcommando voor deze VPS.
  defp faal_tenzij_verwijderd(repo, vps_id) do
    case repo.one(from v in Vps, where: v.id == ^vps_id, lock: "FOR UPDATE") do
      nil -> {:ok, nil}
      %Vps{status: :deleted} = vps -> {:ok, vps}
      %Vps{} = vps -> vps |> Vps.changeset(%{status: :failed}) |> repo.update()
    end
  end

  @doc "Zie `ControlPlane.Provisioning.Teardown.delete_vps/1`."
  defdelegate delete_vps(vps_id), to: Teardown

  @doc "Zie `ControlPlane.Provisioning.Teardown.retry_stuck_deletes/2`."
  defdelegate retry_stuck_deletes(grace_seconds \\ 300, max_backoff_seconds \\ 6 * 3600),
    to: Teardown

  @doc "Zie `ControlPlane.Provisioning.Teardown.retry_orphan_deletes/2`."
  defdelegate retry_orphan_deletes(grace_seconds \\ 300, max_backoff_seconds \\ 6 * 3600),
    to: Teardown

  @doc "Zie `ControlPlane.Provisioning.Power.start_vps/1`."
  defdelegate start_vps(vps_id), to: Power

  @doc "Zie `ControlPlane.Provisioning.Power.stop_vps/1`."
  defdelegate stop_vps(vps_id), to: Power

  @doc "Zie `ControlPlane.Provisioning.Power.pause_vps/1`."
  defdelegate pause_vps(vps_id), to: Power

  @doc "Zie `ControlPlane.Provisioning.Power.resume_vps/1`."
  defdelegate resume_vps(vps_id), to: Power

  @doc "Zie `ControlPlane.Provisioning.Power.reboot_vps/1`."
  defdelegate reboot_vps(vps_id), to: Power

  @doc "Zie `ControlPlane.Provisioning.CommandQueue.deliverable_commands_for_node/1`."
  defdelegate deliverable_commands_for_node(node), to: CommandQueue

  @doc "Zie `ControlPlane.Provisioning.CommandQueue.vastgelopen_commandos/0`."
  defdelegate vastgelopen_commandos(), to: CommandQueue

  @doc "Zie `ControlPlane.Provisioning.CommandQueue.markeer_gemeld/1`."
  defdelegate markeer_gemeld(commandos), to: CommandQueue

  @doc "Zie `ControlPlane.Provisioning.CommandQueue.mark_delivered/1`."
  defdelegate mark_delivered(command), to: CommandQueue

  @doc "Zie `ControlPlane.Provisioning.CommandQueue.mark_delivered_all/1`."
  defdelegate mark_delivered_all(commands), to: CommandQueue

  @doc "Zie `ControlPlane.Provisioning.CommandQueue.max_afleveringen/0`."
  defdelegate max_afleveringen(), to: CommandQueue

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

  @doc "Zie `ControlPlane.Provisioning.GuestName.guest_name/2`."
  defdelegate guest_name(vps, node), to: GuestName

  @doc "Zie `ControlPlane.Provisioning.GuestName.guest_name/1`."
  defdelegate guest_name(vps), to: GuestName

  # Geen plek op een node. De voorwaarde staat in de UPDATE zelf, net als in
  # `Sweeps.faal_wachtende_vps/1`: een VPS die de klant intussen verwijderde,
  # blijft `:deleted`. Geld en abonnement beweegt dit niet; dat doen de aanroeper
  # en de controller, en die zijn allebei eenmalig (terugbetalen merkt de
  # afschrijving, opzeggen slaat een opgezegd abonnement over).
  #
  # Publiek maar ongedocumenteerd, voor de test die dat vastlegt.
  @doc false
  @spec mark_vps_failed(Vps.t()) :: {:ok, Vps.t() | nil}
  def mark_vps_failed(%Vps{id: id}) do
    {_aantal, rijen} =
      Repo.update_all(
        from(v in Vps, where: v.id == ^id and v.status != :deleted, select: v),
        set: [status: :failed, updated_at: Clock.now()]
      )

    {:ok, List.first(rijen)}
  end
end
