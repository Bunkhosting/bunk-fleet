defmodule ControlPlane.Fleet.StilleNodes do
  @moduledoc """
  Een melding aan de operator als een node wegvalt.

  `Fleet.mark_stale_nodes_offline/0` zette een node na twee minuten zonder
  hartslag op `:offline` en vertelde dat aan de open dashboards. Aan niemand
  anders. Een node kon dus acht dagen stil liggen zonder dat iemand het hoorde,
  en dat is gebeurd: Maastricht viel op 24 september weg en op 2 oktober was het
  nog niemand opgevallen.

  ## Waarom een respijttijd

  Er wordt niet gemeld bij het omzetten maar pas als een node al tien minuten
  stil is. Een uitrol laat de agent op VM102 even wegvallen, en een mail per
  uitrol is precies het soort melding dat je leert wegklikken. Tien minuten is
  lang genoeg om dat te overbruggen en kort genoeg dat het ertoe doet.

  ## Eén melding per uitval

  `offline_notified_at` onthoudt dat er gemeld is. Het is dezelfde constructie als
  `stuck_notified_at` bij vastgelopen commando's, en het wordt gewist door de
  eerstvolgende hartslag: een tweede uitval is een nieuwe gebeurtenis en mailt
  dus opnieuw. Zonder dit zou een toestand die dagen duurt elke tik opnieuw
  mailen.
  """
  import Ecto.Query

  require Logger

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Notifier
  alias ControlPlane.Repo

  @stil_na_seconden 10 * 60

  @doc "Hoe lang een node stil moet zijn voordat er gemeld wordt."
  def stil_na_seconden, do: @stil_na_seconden

  @doc """
  Nodes die offline staan, al langer dan de respijttijd, en waarvoor nog niet is
  gemeld.

  Een node zonder enige hartslag (nog nooit online geweest) valt hier buiten: die
  is niet weggevallen, die is nooit begonnen, en een node die nog wacht op zijn
  inschrijving hoort geen alarm te geven.
  """
  @spec te_melden(DateTime.t()) :: [Node.t()]
  def te_melden(nu \\ Clock.now()) do
    grens = DateTime.add(nu, -@stil_na_seconden, :second)

    Repo.all(
      from n in Node,
        where:
          n.status == :offline and not is_nil(n.last_heartbeat_at) and
            n.last_heartbeat_at < ^grens and is_nil(n.offline_notified_at),
        preload: [:region]
    )
  end

  @doc """
  Meldt elke node die daar aan toe is, en geeft terug hoeveel er zijn gemeld.

  Een melding die niet kon worden afgeleverd laat de node ongemarkeerd, zodat de
  volgende ronde het opnieuw probeert -- anders zou een tijdelijk kapotte
  mailserver een uitval voorgoed verzwijgen. Is er helemaal geen operatoradres
  ingesteld, dan valt er niets opnieuw te proberen, en dan wordt hij wél
  gemarkeerd: anders blijft hij elke ronde een foutregel loggen over iets wat
  alleen een mens kan oplossen.
  """
  @spec melden(DateTime.t()) :: non_neg_integer()
  def melden(nu \\ Clock.now()) do
    Enum.count(te_melden(nu), fn node ->
      case Notifier.deliver_operational_alert(onderwerp(node), tekst(node, nu)) do
        result when result == :ok or result == {:error, :no_ops_email} ->
          markeer(node, nu)
          result == :ok

        {:error, reden} ->
          Logger.warning(
            "melding over stille node #{node.name} niet verstuurd: #{inspect(reden)}"
          )

          false
      end
    end)
  end

  defp markeer(%Node{id: id}, nu) do
    Repo.update_all(from(n in Node, where: n.id == ^id),
      set: [offline_notified_at: nu, updated_at: nu]
    )
  end

  # De naam in het onderwerp, want de rem op meldingen telt per onderwerp: twee
  # nodes die tegelijk wegvallen zijn twee meldingen, geen ene die de ander
  # afknijpt.
  defp onderwerp(%Node{name: naam}), do: "Node #{naam} reageert niet meer"

  defp tekst(%Node{} = node, nu) do
    stil = DateTime.diff(nu, node.last_heartbeat_at, :second)

    """
    De node #{node.name} (#{regio(node)}) heeft sinds #{node.last_heartbeat_at} UTC niets
    meer van zich laten horen -- #{duur(stil)}.

    #{vpsen(node)}

    Dat zegt nog niet wat er aan de hand is. Staat de machine uit, of is alleen de
    agent gestopt? Draait de machine nog, kijk dan op de node zelf:

      systemctl status bunk-worker
      journalctl -u bunk-worker --since -1h

    Dit bericht komt één keer per uitval. Komt de node terug en valt hij later
    opnieuw weg, dan volgt er een nieuwe.
    """
  end

  defp regio(%Node{region: %{code: code}}), do: "regio #{code}"
  defp regio(%Node{}), do: "geen regio"

  defp vpsen(%Node{id: id}) do
    aantal =
      Repo.aggregate(
        from(v in Vps, where: v.node_id == ^id and v.status not in [:deleted, :failed]),
        :count
      )

    case aantal do
      0 ->
        "Er draait geen enkele VPS op deze node, dus er zijn geen klanten door geraakt."

      n ->
        "Er staan #{n} actieve VPS'en op deze node. Die zijn voor ons niet meer te beheren, " <>
          "en een klant komt er niet meer in via de webterminal."
    end
  end

  defp duur(seconden) when seconden < 3600, do: "#{div(seconden, 60)} minuten"
  defp duur(seconden) when seconden < 86_400, do: "#{div(seconden, 3600)} uur"
  defp duur(seconden), do: "#{div(seconden, 86_400)} dagen"
end
