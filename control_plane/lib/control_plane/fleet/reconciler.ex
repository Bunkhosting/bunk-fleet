defmodule ControlPlane.Fleet.Reconciler do
  @moduledoc """
  Background reconciler that flips stale nodes to `:offline`.

  Nodes report heartbeats; a node whose agent dies keeps `status: :online` in the
  database forever (the heartbeat TTL only hides it from the scheduler), so the
  operator dashboard would keep showing a dead node as online. On a fixed
  interval this GenServer calls `ControlPlane.Fleet.mark_stale_nodes_offline/0`,
  which marks every `:online` node with a stale/absent heartbeat as `:offline`.

  Each tick also drives billing: after reconciling node health it meters every
  active VPS into `usage_records` (see `ControlPlane.Billing.meter_active_vpses/0`),
  which is how we account for the resource-hours our own nodes actually serve.

  ## Crash policy

  We deliberately wrap each tick in a `try/rescue`: a transient failure (e.g. a
  brief database blip) is logged and the next tick is rescheduled rather than
  crashing the process. This keeps reconciliation running through transient
  errors instead of relying on the supervisor to restart us — which, with a
  `:one_for_one` restart limit, could otherwise tear the process down for good
  after repeated failures.

  The node-reconcile and metering sub-steps are wrapped *independently* so that a
  failure in one does not skip the other (e.g. a metering blip must not stop dead
  nodes from being flipped offline).
  """
  use GenServer

  require Logger

  alias ControlPlane.Accounts
  alias ControlPlane.Backups
  alias ControlPlane.Billing
  alias ControlPlane.Credits
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.AgentUpdate
  alias ControlPlane.Fleet.Drift
  alias ControlPlane.Fleet.HartslagNaarBuiten
  alias ControlPlane.Provisioning
  alias ControlPlane.Schijfruimte
  alias ControlPlane.Subscriptions

  @default_interval_ms 30_000

  # Metering is time-delta based (each usage_records row stores the seconds since
  # that VPS's previous meter), so the cadence never changes the billed total — it
  # only bounds how fast usage_records grows and how often EVERY active VPS is
  # locked FOR UPDATE. Running it hourly instead of on every 30s tick cuts row
  # growth and lock churn ~120x at scale. Override with `:meter_interval_ms`.
  @default_meter_interval_ms 60 * 60 * 1000

  # Backups are dispatched from the same tick, gated the same way. Checking which
  # VPSes are due is one query; actually taking one is minutes of the node's disk,
  # and `Backups.run_due/1` only dispatches for VPSes whose last backup is older
  # than the configured interval — so this cadence bounds how often we ask, not
  # how often a customer's VPS is backed up. Override with `:backup_check_interval_ms`.
  @default_backup_check_interval_ms 15 * 60 * 1000

  # Elk half uur. Drift ontstaat door handwerk op een hypervisor en door
  # mislukte uitrollen; dat gaat niet sneller dan een mens typt, en vaker vragen
  # zet alleen commando's in de weg van echt werk.
  @default_drift_interval_ms 30 * 60 * 1000

  # Vier keer per dag. Het gaat om rijen van drie maanden oud; of die er een paar
  # uur langer staan maakt niemand uit, en vaker kijken betekent vaker een query
  # die niets vindt.
  @default_purge_interval_ms 6 * 60 * 60 * 1000

  # Eens per zes uur kijken hoe vol de schijf zit. Vaker heeft geen zin -- een
  # schijf loopt niet in een kwartier vol -- en een melding die vaker komt dan
  # iemand er iets aan kan doen, is een melding die niemand meer leest.
  @default_schijf_interval_ms 6 * 60 * 60 * 1000

  # Hoogstens één melding per etmaal over de schijf. Een volle schijf is geen
  # gebeurtenis maar een toestand: hij blijft vol tot iemand er iets aan doet, en
  # vier keer per dag hetzelfde zeggen is hoe een melding een ding wordt dat je
  # wegklikt.
  @alarm_stilte_ms 24 * 60 * 60 * 1000

  @doc """
  Starts the reconciler.

  Options:

    * `:interval_ms` - milliseconds between reconciliation ticks
      (default `#{@default_interval_ms}`).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    meter_interval_ms = Keyword.get(opts, :meter_interval_ms, @default_meter_interval_ms)

    backup_check_interval_ms =
      Keyword.get(opts, :backup_check_interval_ms, @default_backup_check_interval_ms)

    drift_interval_ms = Keyword.get(opts, :drift_interval_ms, @default_drift_interval_ms)
    purge_interval_ms = Keyword.get(opts, :purge_interval_ms, @default_purge_interval_ms)
    schijf_interval_ms = Keyword.get(opts, :schijf_interval_ms, @default_schijf_interval_ms)

    schedule_tick(interval_ms)
    HartslagNaarBuiten.meld_stand()

    {:ok,
     %{
       interval_ms: interval_ms,
       meter_interval_ms: meter_interval_ms,
       last_meter_ms: nil,
       backup_check_interval_ms: backup_check_interval_ms,
       last_backup_check_ms: nil,
       drift_interval_ms: drift_interval_ms,
       last_drift_ms: nil,
       purge_interval_ms: purge_interval_ms,
       last_purge_ms: nil,
       last_scrub_ms: nil,
       schijf_interval_ms: schijf_interval_ms,
       last_schijf_ms: nil,
       last_schijf_alarm_ms: nil,
       last_hartslag_ms: nil
     }}
  end

  @impl true
  def handle_info(:reconcile, %{interval_ms: interval_ms} = state) do
    # De volgende tik wordt ALTIJD gezet, ook als het werk hieronder ontploft.
    #
    # Dit is een klok, en een klok die stilvalt neemt alles mee: metering,
    # facturatie, back-ups, het opruimen van vastgelopen VPS'en. `send_after`
    # stuurt naar dit proces zelf, dus een crash gooit ook het geplande bericht
    # weg -- de supervisor start wel opnieuw op, maar bij een fout die elke tik
    # terugkomt is dat een stille lus in plaats van werk.
    #
    # Elke sub-stap heeft zijn eigen `rescue` zodat een fout in de ene de andere
    # niet meesleept; dit is het vangnet daaronder, voor de stap die er ooit
    # zonder wordt toegevoegd. Dat is geen theorie: `roll_out_agent/0` stond hier
    # zonder, en stond bovendien vlak vóór `schedule_tick/1`.
    state = tik(state)
    schedule_tick(interval_ms)
    {:noreply, state}
  end

  defp tik(state) do
    reconcile_nodes()
    reclaim_reservations()
    fail_stuck_creates()
    fail_stuck_provisionings()
    refund_orphan_charges()
    retry_stuck_deletes()
    state = maybe_meter_usage(state)
    state = maybe_dispatch_backups(state)
    state = maybe_purge_commands(state)
    state = maybe_scrub_vpses(state)
    state = maybe_check_schijf(state)
    settle_subscriptions()
    roll_out_agent()
    meld_vastgelopen_commandos()
    ruim_vastgelopen_backups_op()
    state = maybe_check_drift(state)

    # Helemaal achteraan, en dat is de hele betekenis: dit levensteken zegt niet
    # "het proces bestaat" maar "deze ronde is van begin tot eind doorlopen".
    # Een tik die halverwege omvalt, komt hier niet.
    maybe_piep(state)
  rescue
    exception ->
      Logger.error(
        "fleet reconciler tick faalde buiten de afgevangen stappen om: " <>
          Exception.message(exception),
        crash_reason: {exception, __STACKTRACE__}
      )

      state
  catch
    # Een uitgeputte databasepool komt niet als een exception binnen maar als een
    # exit. Precies de fout die je bij drukte krijgt, en precies het moment
    # waarop de klok moet blijven lopen.
    :exit, reason ->
      Logger.error("fleet reconciler tick stopte met een exit: #{inspect(reason)}")
      state
  end

  # Meter only once per meter_interval_ms (default hourly), not every tick. Uses a
  # monotonic clock so it's immune to wall-clock jumps; the first tick after boot
  # meters immediately (last_meter_ms is nil), catching up any elapsed runtime.
  defp maybe_meter_usage(%{meter_interval_ms: mi, last_meter_ms: last} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= mi do
      meter_usage()
      # Lift mee op dezelfde uurslag. Verlopen sessies worden door de query toch
      # al geweigerd, dus dit is opruimen en geen beveiliging — een eigen timer
      # ernaast zetten zou meer bewegende delen zijn dan het werk waard is.
      purge_sessions()
      %{state | last_meter_ms: now}
    else
      state
    end
  end

  # Elke node vragen wat hij werkelijk heeft, en dat met de administratie
  # vergelijken. Niet elke tik: het antwoord verandert traag, en de agent
  # verwerkt commando's één voor één -- een inventarisatie die voor een
  # provision in de rij komt kost een klant wachttijd.
  defp maybe_check_drift(%{drift_interval_ms: di, last_drift_ms: last} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= di do
      check_drift()
      %{state | last_drift_ms: now}
    else
      state
    end
  end

  defp maybe_check_drift(state), do: state

  # Afgehandelde commando's van drie maanden oud. Zie
  # `Provisioning.purge_old_commands/2` voor waarom die weg mogen en waarom er
  # een bovengrens per ronde op zit.
  defp maybe_purge_commands(%{purge_interval_ms: pi, last_purge_ms: last} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= pi do
      purge_commands()
      %{state | last_purge_ms: now}
    else
      state
    end
  end

  defp maybe_purge_commands(state), do: state

  # Wat er van een verwijderde VPS niet bewaard hoeft te blijven. Dezelfde
  # cadans als het opruimen van commando's: het gaat om rijen van een maand oud,
  # dus vier keer per dag kijken is ruim genoeg.
  defp maybe_scrub_vpses(%{purge_interval_ms: pi, last_scrub_ms: last} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= pi do
      scrub_vpses()
      %{state | last_scrub_ms: now}
    else
      state
    end
  end

  defp maybe_scrub_vpses(state), do: state

  defp scrub_vpses do
    case Fleet.scrub_deleted_vpses() do
      0 -> :ok
      n -> Logger.info("persoonsgegevens gewist van verwijderde vps'en", count: n)
    end
  rescue
    e -> Logger.error("opschonen van verwijderde vps'en mislukt: #{Exception.message(e)}")
  end

  # Hoe vol de schijf zit. Loopt hij vol, dan stopt Postgres met schrijven en
  # ligt alles plat -- en het eerste signaal zou anders een klant zijn.
  defp maybe_check_schijf(%{schijf_interval_ms: si, last_schijf_ms: last} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= si do
      %{
        state
        | last_schijf_ms: now,
          last_schijf_alarm_ms: check_schijf(state.last_schijf_alarm_ms)
      }
    else
      state
    end
  end

  defp maybe_check_schijf(state), do: state

  defp maybe_piep(%{last_hartslag_ms: last} = state),
    do: %{state | last_hartslag_ms: HartslagNaarBuiten.piep(last)}

  # Een staat zonder deze sleutel bestaat alleen in tests, die hem bewust
  # minimaal opbouwen. Stil overslaan mag hier: of deze switch werkt, blijkt
  # niet uit onze eigen log maar uit de dienst aan de andere kant -- die
  # alarmeert juist wanneer het levensteken uitblijft.
  defp maybe_piep(state), do: state

  # Een back-up staat op :running tot de node terugmeldt. Meldt hij nooit terug,
  # dan blijft die rij staan -- op productie stond er een sinds twee dagen
  # "bezig" in het dashboard van een klant. Sinds er maar één lopende back-up per
  # VPS mag zijn, houdt zo'n rij bovendien elke volgende back-up tegen.
  defp ruim_vastgelopen_backups_op do
    case Backups.fail_vastgelopen() do
      {0, _} -> :ok
      {n, _} -> Logger.warning("#{n} vastgelopen back-up(s) op mislukt gezet")
    end
  rescue
    exception ->
      Logger.error("opruimen van vastgelopen back-ups mislukte: #{Exception.message(exception)}")
  end

  # Een commando dat vaak genoeg is uitgedeeld en nog steeds geen resultaat
  # opleverde, wordt niet meer aangeboden aan de node. Daarmee is het uit de
  # eeuwige lus -- en meteen ook uit het zicht, want er gebeurt dan helemaal
  # niets meer. Een VPS die in "aanmaken" blijft staan terwijl hij op de node
  # draait, is precies het geval waarin de klant het als eerste merkt.
  #
  # Dus melden, niet opruimen: het werk is waarschijnlijk juist wél gedaan, en
  # zo'n commando alsnog laten falen zou een draaiende machine terugbetalen en
  # verwijderen.
  defp meld_vastgelopen_commandos do
    case Provisioning.vastgelopen_commandos() do
      [] ->
        :ok

      commandos ->
        regels =
          Enum.map_join(commandos, "\n", fn c ->
            "  #{c.kind} voor vps #{c.vps_id || "-"} (#{c.delivery_count} keer uitgedeeld)"
          end)

        Logger.error("#{length(commandos)} commando(s) zitten vast in herlevering")

        ControlPlane.Notifier.deliver_operational_alert(
          "#{length(commandos)} commando(s) zitten vast in herlevering",
          """
          Deze commando's zijn #{Provisioning.max_afleveringen()} keer of vaker
          aan een node gegeven zonder dat er ooit een resultaat terugkwam:

          #{regels}

          Dat betekent meestal niet dat het werk mislukte, maar dat het
          terugmelden mislukte -- de VPS draait dan gewoon terwijl hij bij de
          klant in "aanmaken" staat. Kijk op de node of de machine er is, en zet
          het commando daarna met de hand op done of failed.

          Dit bericht komt één keer per commando. Blijft de toestand bestaan,
          dan blijft hij zichtbaar in het beheerscherm -- maar hij mailt niet
          opnieuw.
          """
        )

        # Pas markeren NA het versturen: gaat het melden mis, dan hoort het bij
        # de volgende tik opnieuw geprobeerd te worden in plaats van stil te
        # verdwijnen.
        Provisioning.markeer_gemeld(commandos)
    end
  rescue
    exception ->
      Logger.error("melden van vastgelopen commando's mislukte: #{Exception.message(exception)}")
  end

  defp check_schijf(laatste_alarm) do
    now = System.monotonic_time(:millisecond)

    case Schijfruimte.te_vol?() do
      {true, pct} when is_nil(laatste_alarm) or now - laatste_alarm >= @alarm_stilte_ms ->
        Logger.error("schijf zit op #{pct}%", schijf_pct: pct)

        ControlPlane.Notifier.deliver_operational_alert(
          "De schijf van de control plane zit op #{pct}%",
          """
          Het bestandssysteem waar de control plane, de database en de
          bouwomgeving op staan zit op #{pct}% (de grens ligt op
          #{Schijfruimte.drempel()}%).

          Loopt hij helemaal vol, dan stopt Postgres met schrijven en ligt het
          platform plat. Wat er meestal aan de hand is: oude images en
          bouw-cache. `docker image prune` en `docker builder prune` (NOOIT
          `docker volume prune` -- daar staan de klantgegevens in) ruimen het
          meeste op.
          """
        )

        now

      # Nog steeds te vol, maar het is al gemeld. De logregel blijft, de mail
      # niet -- zo is in de log wel te zien dat het niet vanzelf overging.
      {true, pct} ->
        Logger.warning("schijf zit nog steeds op #{pct}%", schijf_pct: pct)
        laatste_alarm

      false ->
        laatste_alarm
    end
  rescue
    e ->
      Logger.error("schijfcontrole mislukt: #{Exception.message(e)}")
      laatste_alarm
  end

  defp purge_commands do
    case Provisioning.purge_old_commands() do
      0 -> :ok
      n -> Logger.info("oude commando's opgeruimd", count: n)
    end
  rescue
    e -> Logger.error("opruimen van commando's mislukt: #{Exception.message(e)}")
  end

  defp check_drift do
    case Drift.request_all() do
      0 -> :ok
      n -> Logger.info("driftcontrole: inventarisatie gevraagd aan #{n} node(s)")
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler driftcontrole faalde: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp maybe_dispatch_backups(%{backup_check_interval_ms: bi, last_backup_check_ms: last} = state) do
    now = System.monotonic_time(:millisecond)

    if is_nil(last) or now - last >= bi do
      dispatch_backups()
      %{state | last_backup_check_ms: now}
    else
      state
    end
  end

  defp dispatch_backups do
    summary = Backups.run_due()

    if summary.started > 0 or summary.errors > 0 do
      Logger.info("backups dispatched", started: summary.started, errors: summary.errors)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler backup dispatch failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp reconcile_nodes do
    {count, _} = Fleet.mark_stale_nodes_offline()

    if count > 0 do
      Logger.info("fleet reconciler marked stale nodes offline", marked_offline: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler node tick failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp reclaim_reservations do
    count = Fleet.release_orphaned_reservations()

    if count > 0 do
      Logger.info("fleet reconciler reclaimed orphaned reservations", reclaimed: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler reservation reclaim failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp fail_stuck_creates do
    count = Provisioning.fail_stuck_queued_vpses()

    if count > 0 do
      # Hard, en naar een mens: elke rij hier is een klant die betaalde voor een
      # VPS die nooit is aangemaakt. De sweep haalt de rij uit het ongewisse; of
      # er iets kapot is dat dit blijft veroorzaken, ziet alleen iemand die kijkt.
      Logger.error("failed #{count} vps(es) that were queued but never dispatched")

      ControlPlane.Notifier.deliver_operational_alert(
        "#{count} VPS(en) betaald maar nooit aangemaakt",
        """
        #{count} VPS-rij(en) stonden voorbij de coulanceperiode op :queued zonder
        commando erachter. Dat betekent dat de control plane is gestopt tussen
        het vastleggen en het uitsturen. Ze staan nu op :failed.

        De afschrijving is automatisch teruggeboekt: sinds het grootboek de
        vps_id meeschrijft, zoekt de sweep de bijbehorende vps_charge op en
        draait hem terug. In de log staat per VPS of er een afschrijving is
        gevonden; staat er "No charge was found for it", dan was er niets om
        terug te boeken.

        Controleer dus niet het geld maar de oorzaak: dit hoort niet te
        gebeuren. Kijk naar herstarts van de control plane, geheugengebruik en
        uitrollen rond de tijdstippen in de log.
        """
      )
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler stuck-create sweep failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  # De VPS die wél werd uitgestuurd maar op een node belandde die daarna wegviel.
  # `fail_stuck_creates/0` hierboven ziet die niet: die kijkt naar :queued, en
  # deze staat op :provisioning.
  defp fail_stuck_provisionings do
    count = Provisioning.fail_stuck_provisioning_vpses()

    if count > 0 do
      Logger.error("#{count} vps(en) losgemaakt van een node die niet meer terugkwam")

      ControlPlane.Notifier.deliver_operational_alert(
        "#{count} VPS(en) vastgelopen op een verdwenen node",
        """
        #{count} VPS(en) stonden op :provisioning terwijl hun node offline is en
        het provision-commando nooit een resultaat opleverde. Ze zijn als mislukt
        afgehandeld: het abonnement is teruggeboekt en de gereserveerde
        capaciteit is vrijgegeven.

        Wat dit NIET doet is een half aangemaakte VM opruimen -- de agent heeft
        nooit een vm_id gemeld. Komt de node terug, kijk dan naar de
        driftmelding: een gast binnen het VMID-bereik die wij niet kennen is
        hiervan het overblijfsel.
        """
      )
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler stuck-provisioning sweep faalde: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  # A charge whose VPS never came into being. The create path refunds on every
  # failure it can see, including an exception and an exit; this covers the one it
  # cannot — the process being killed outright between debiting the wallet and
  # creating the machine.
  defp refund_orphan_charges do
    count = Credits.refund_orphan_charges()

    if count > 0 do
      Logger.error("refunded #{count} charge(s) for VPSes that were never created")

      ControlPlane.Notifier.deliver_operational_alert(
        "#{count} betaling(en) teruggeboekt voor VPSen die nooit bestonden",
        """
        #{count} afschrijving(en) in het grootboek hoorden bij een VPS die nooit
        is aangemaakt. Het geld is automatisch teruggeboekt.

        Dit gebeurt als de control plane omvalt tussen het afschrijven en het
        aanmaken. Eén keer is ruis; vaker betekent dat er iets de control plane
        hardhandig neerhaalt - kijk naar herstarts, geheugengebruik en deploys
        rond de tijdstippen in de log.
        """
      )
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler orphan-charge sweep failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp retry_stuck_deletes do
    count = Provisioning.retry_stuck_deletes()

    if count > 0 do
      Logger.info("fleet reconciler retried failed teardowns", retried: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler delete-retry sweep failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp purge_sessions do
    case Accounts.purge_expired_sessions() do
      0 -> :ok
      n -> Logger.info("verlopen sessies opgeruimd", count: n)
    end
  rescue
    e -> Logger.error("opruimen van sessies mislukt: #{Exception.message(e)}")
  end

  defp meter_usage do
    # Single-instance assumption: metering runs from this one reconciler process.
    # `Billing.meter_active_vpses/0` locks each VPS row FOR UPDATE so overlapping
    # ticks can't double-bill; running multiple control-plane instances would
    # additionally need leader election / an advisory lock around the tick. The
    # UNIQUE (vps_id, metered_at) index on usage_records is the data-layer backstop.
    count = Billing.meter_active_vpses()

    if count > 0 do
      Logger.info("fleet reconciler metered active vpses", metered: count)
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler metering tick failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp settle_subscriptions do
    # Charge subscriptions that have come due and suspend/resume VPSes on the
    # customer's wallet balance. Cheap on an idle day: the due-query is
    # indexed and each due subscription advances its own date, so a subscription
    # is touched at most once per day regardless of the 30s tick.
    summary = Subscriptions.settle_due()

    if summary.charged > 0 or summary.suspended > 0 or summary.resumed > 0 do
      Logger.info(
        "recurring billing: charged=#{summary.charged} suspended=#{summary.suspended} " <>
          "resumed=#{summary.resumed} cancelled=#{summary.cancelled} errors=#{summary.errors}"
      )
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler subscription settle failed: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  # De agent-uitrol gaat in golven: eerst één node als kanarie, daarna de rest.
  # Deze tik is wat hem vooruit duwt — er gebeurt alleen iets als er iets te doen
  # is, en zodra alles op de doelversie zit is het een enkele query.
  defp roll_out_agent do
    case AgentUpdate.dispatch_wave() do
      {:dispatched, n} -> Logger.info("agent-uitrol: update klaargezet voor #{n} node(s)")
      _ -> :ok
    end
  rescue
    exception ->
      Logger.error(
        "fleet reconciler agent-uitrol faalde: #{Exception.message(exception)}",
        crash_reason: {exception, __STACKTRACE__}
      )
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :reconcile, interval_ms)
  end
end
