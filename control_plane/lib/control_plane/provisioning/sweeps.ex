defmodule ControlPlane.Provisioning.Sweeps do
  @moduledoc """
  Opruimrondes voor VPS'en die in een tussenstand zijn blijven hangen.

  Elke ronde zoekt rijen waar niemand meer iets mee gaat doen en brengt ze naar
  een eerlijke eindstand:

    * `fail_stuck_queued_vpses/1` -- opgeslagen maar nooit uitgestuurd; de VPS
      wordt `:failed` en de afschrijving gaat terug;
    * `fail_stuck_provisioning_vpses/1` -- de uitrol hangt op een node die offline
      is; afgehandeld als mislukte uitrol, met terugbetaling;
    * `fail_stuck_restores/1` -- een terugzetactie waarvan het resultaat nooit
      kwam; de VPS gaat naar `:stopped`.

  Waar een agentresultaat de afloop bepaalt, gaat het via
  `ControlPlane.Provisioning.apply_result/2` met een verzonnen mislukking, zodat
  terugbetalen en capaciteit vrijgeven dezelfde code doorlopen als wanneer een
  agent zelf een fout meldt. De reconciler roept deze rondes periodiek aan.
  """
  import Ecto.Query
  require Logger

  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Events
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  @doc """
  Fails VPSes that were persisted but never dispatched, and says how many.

  `create_vps/1` inserts the row `:queued` and then places it. Between those two
  the control plane can stop — a deploy, a crash — and what is left is a row
  nobody will ever act on: no command, no reservation, no node, and a customer
  who has already been charged. It counts against their quota and shows in their
  dashboard as something about to happen, forever.

  Marking it `:failed` is the honest end state: the customer can see it went
  wrong and delete it, and it stops occupying a quota slot. The charge is
  refunded in the same transaction: the ledger carries the VPS id, so there is
  no guessing about which entry to reverse.
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

    # Per VPS één transactie: eerst de rij voorwaardelijk op :failed, en alleen
    # als dat lukt het geld terug. Andersom -- eerst terugbetalen, dan alle ids
    # in één keer op :failed -- liet een gat. Een uitsturing die tussen de select
    # en de update alsnog doorkwam, zette de VPS op :provisioning; de update
    # overschreef dat zonder te kijken, en de klant kreeg een draaiende machine
    # met zijn geld terug. De voorwaarde staat nu in de UPDATE zelf: Postgres
    # wacht op het slot van die uitsturing en kijkt daarna opnieuw.
    count = Enum.count(stuck, &faal_wachtende_vps/1)

    if count > 0, do: Events.broadcast_changed(:vps)
    count
  end

  # Publiek voor de test die het gat hierboven vastlegt; verder alleen van hier.
  @doc false
  def faal_wachtende_vps(vps_id) do
    {:ok, gefaald?} =
      Repo.transaction(fn ->
        {n, _} =
          Repo.update_all(
            from(v in Vps,
              as: :vps,
              where: v.id == ^vps_id and v.status == :queued,
              where:
                not exists(from c in Command, where: c.vps_id == parent_as(:vps).id, select: 1)
            ),
            set: [status: :failed, updated_at: Clock.now()]
          )

        if n == 1, do: betaal_wachtende_terug(vps_id)

        n == 1
      end)

    gefaald?
  end

  defp betaal_wachtende_terug(vps_id) do
    # The charge carries the VPS id since the ledger learned about machines, so
    # the money can go back here instead of in a sentence telling a person to go
    # and look for it.
    refunded = Credits.refund_charge_for_vps(vps_id)

    Logger.error(
      "vps #{vps_id} was queued but never dispatched; failing it. " <>
        if(refunded, do: "The charge has been refunded.", else: "No charge was found for it.")
    )
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
          # :deleting hoort erbij: een klant die verwijderde terwijl de uitrol
          # liep, krijgt een uitgestelde afbraak die op het resultaat van die
          # uitrol wacht. Valt de node weg, dan komt dat resultaat nooit, en
          # bleef de VPS voorgoed op "wordt verwijderd" staan, met de capaciteit
          # geboekt.
          where: v.status in [:provisioning, :deleting],
          where: n.status == :offline,
          where: c.inserted_at < ^cutoff
      )

    Enum.each(gestrand, fn command ->
      Logger.error(
        "vps #{command.vps_id} hangt in :provisioning op node #{command.node_id}, " <>
          "die offline is; de bestelling wordt als mislukt afgehandeld en terugbetaald"
      )

      Provisioning.apply_result(command, %{
        "status" => "failed",
        "error" => "node unreachable: provision never reported a result"
      })
    end)

    length(gestrand)
  end

  @doc """
  Haalt VPS'en uit `:restoring` die daar nooit meer uit zouden komen.

  Een terugzetactie wordt alleen afgesloten door het resultaat van de agent.
  Komt dat nooit -- de node valt weg, het resultaat gaat verloren -- dan stond
  de VPS voorgoed op "terugzetten", en blokkeerde dat elke andere knop.

  Twee gevallen:

    * het commando loopt al langer dan `uren` uur: dan wordt het als mislukt
      afgehandeld, wat de VPS op `:stopped` zet (niet op `:active`: de schijf
      kan half geschreven zijn);
    * er is geen lopend terugzetcommando meer, maar de VPS staat er al een half
      uur op: dan is er niets meer dat hem verplaatst, en gaat hij direct naar
      `:stopped`.

  Geeft het aantal losgemaakte VPS'en terug.
  """
  @spec fail_stuck_restores(pos_integer()) :: non_neg_integer()
  def fail_stuck_restores(uren \\ 6) do
    grens = Clock.shift(-uren * 3600)

    te_lang =
      Repo.all(
        from c in Command,
          join: v in Vps,
          on: v.id == c.vps_id,
          where: c.kind == :restore_backup and c.status in [:pending, :delivered],
          where: v.status == :restoring and c.inserted_at < ^grens
      )

    Enum.each(te_lang, fn command ->
      Logger.error("terugzetten van vps #{command.vps_id} meldde niets terug binnen #{uren} uur")

      Provisioning.apply_result(command, %{
        "status" => "failed",
        "error" => "de node meldde niets terug binnen #{uren} uur"
      })
    end)

    lopend =
      from c in Command,
        where:
          c.vps_id == parent_as(:vps).id and c.kind == :restore_backup and
            c.status in [:pending, :delivered],
        select: 1

    {zwevend, _} =
      Repo.update_all(
        from(v in Vps,
          as: :vps,
          where: v.status == :restoring and v.updated_at < ^Clock.shift(-1800),
          where: not exists(lopend)
        ),
        set: [status: :stopped, updated_at: Clock.now()]
      )

    length(te_lang) + zwevend
  end
end
