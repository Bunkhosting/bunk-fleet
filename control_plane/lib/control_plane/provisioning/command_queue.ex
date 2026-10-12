defmodule ControlPlane.Provisioning.CommandQueue do
  @moduledoc """
  De wachtrij van commando's tussen het control plane en de agents op de nodes.

  Een node haalt zijn werk op via `deliverable_commands_for_node/1` en elk
  commando dat hij meekrijgt wordt gemarkeerd met `mark_delivered/1` of, voor een
  hele lading tegelijk, `mark_delivered_all/1`. Komt er geen resultaat terug --
  de agent viel om voordat hij het kwijt kon -- dan wordt het commando na een
  termijn opnieuw uitgedeeld. Dat mag alleen omdat de agent idempotent is: een
  herhaald commando voor werk dat al gedaan is, meldt hetzelfde resultaat nog een
  keer.

  Een commando dat te vaak is uitgedeeld zonder ooit een resultaat op te leveren
  gaat niet eeuwig snel rond. Het wordt nog eens per half uur aangeboden en via
  `vastgelopen_commandos/0` en `markeer_gemeld/1` één keer aan een mens gemeld.

  Afgehandelde commando's die oud genoeg zijn ruimt `purge_old_commands/2` op,
  in begrensde porties zodat de tabel niet lang op slot zit.
  """
  import Ecto.Query

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Repo

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

  # Daarboven: niet nooit meer, maar langzaam. "Nooit meer" maakte het
  # vastlopen permanent: het geheugen van de agent herhaalt een resultaat
  # alleen als het control plane ernaar vraagt, en dat vroeg het niet meer. Een
  # uitrol die klaar was maar zijn resultaat niet kwijt kon (het control plane
  # stond net te herstarten), bleef zo voorgoed in "aanmaken" staan. Eens per
  # half uur is genoeg om dat te herstellen en weinig genoeg om niets te
  # belasten.
  @trage_herlevering_seconds 1800

  # Back-ups en terugzetten duren normaal veel langer dan 90 seconden, en de
  # agent zwijgt zolang hij bezig is. Met de gewone termijn haalden ze binnen
  # acht minuten de grens en kwam er een "commando's zitten vast"-mail voor werk
  # dat gewoon liep.
  @lang_werk [:backup, :restore_backup]
  @lang_werk_ttl_seconds 900

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
    Repo.all(
      from c in Command,
        where: c.node_id == ^node_id,
        where: ^dynamic([c], c.status == :pending or ^opnieuw_uit_te_delen()),
        order_by: [asc: c.inserted_at]
    )
  end

  # Een afgeleverd commando zonder resultaat gaat opnieuw de deur uit: na de
  # gewone termijn (langer voor back-ups en terugzetten), en boven de grens nog
  # eens per half uur.
  defp opnieuw_uit_te_delen do
    dynamic(
      [c],
      c.status == :delivered and not is_nil(c.delivered_at) and
        (^binnen_de_grens() or ^boven_de_grens())
    )
  end

  defp binnen_de_grens do
    cutoff = Clock.shift(-@redelivery_ttl_seconds)
    cutoff_lang = Clock.shift(-@lang_werk_ttl_seconds)

    dynamic(
      [c],
      c.delivery_count < ^@max_afleveringen and
        ((c.kind in ^@lang_werk and c.delivered_at < ^cutoff_lang) or
           (c.kind not in ^@lang_werk and c.delivered_at < ^cutoff))
    )
  end

  defp boven_de_grens do
    cutoff_traag = Clock.shift(-@trage_herlevering_seconds)
    dynamic([c], c.delivery_count >= ^@max_afleveringen and c.delivered_at < ^cutoff_traag)
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
        where:
          c.status == :delivered and c.delivery_count >= ^@max_afleveringen and
            is_nil(c.stuck_notified_at),
        order_by: [asc: c.inserted_at],
        preload: [:vps]
    )
  end

  @doc """
  Merkt deze commando's als gemeld, zodat het bij één melding blijft.

  Een toestand die blijft bestaan hoort niet elk uur opnieuw een mail op te
  leveren: na de eerste weet de lezer het, en elke volgende maakt de kans
  kleiner dat hij de volgende écht leest. Dit is precies de fout die hier zat --
  88 foutregels en drie mails per uur over drie commando's die één keer bekeken
  hadden moeten worden.
  """
  @spec markeer_gemeld([Command.t()]) :: {non_neg_integer(), nil}
  def markeer_gemeld([]), do: {0, nil}

  def markeer_gemeld(commandos) do
    ids = Enum.map(commandos, & &1.id)
    nu = Clock.now()

    Repo.update_all(
      from(c in Command, where: c.id in ^ids),
      set: [stuck_notified_at: nu, updated_at: nu]
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
  redelivery) but without the N+1.

  Returns `{count, ids}`: the ids that were actually marked. Only those may go to
  the agent. A command that a concurrent delete cancelled between the poll's read
  and this write is skipped by the guard below -- and if the caller still sent
  it, the agent built a VM for a VPS that no longer exists.
  """
  @spec mark_delivered_all([Command.t()]) :: {non_neg_integer(), [Ecto.UUID.t()]}
  def mark_delivered_all([]), do: {0, []}

  def mark_delivered_all(commands) do
    ids = Enum.map(commands, & &1.id)
    ts = Clock.now()

    # Guard on non-terminal status: a concurrent apply_result / cancel_and_release
    # may have moved a command to :done/:failed between the poll's read and this
    # write. Without the guard we'd resurrect a cancelled command back to
    # :delivered and hand the agent a provision/delete it must not run (orphan VM,
    # double-booked capacity).
    Repo.update_all(
      from(c in Command,
        where: c.id in ^ids and c.status in [:pending, :delivered],
        select: c.id
      ),
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

  # True if a command of this kind for this VPS is queued or already with the
  # agent, and so has not reported back yet.
  @doc false
  def in_flight?(vps_id, kind) do
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
  @doc false
  def provision_in_flight?(vps_id) do
    Repo.exists?(
      from c in Command,
        where: c.vps_id == ^vps_id and c.kind == :provision and c.status == :delivered
    )
  end
end
