defmodule ControlPlane.Fleet.Drift do
  @moduledoc """
  Houdt de administratie tegen wat er werkelijk op een node draait.

  Het control plane is de bron van waarheid over een VPS: status, adres,
  provider-id. Dat is een goede keuze -- de node is niet te vertrouwen als
  boekhouding en kan wegvallen -- maar het heeft een keerzijde die niemand ziet
  totdat het geld kost: **niemand vergelijkt die twee ooit**.

  Twee richtingen, allebei duur:

    * Een VPS die wij `:active` noemen en die op de node niet meer bestaat.
      Iemand heeft hem met de hand van de hypervisor gehaald, of een uitrol is
      halverwege gestrand. De klant wordt elk uur gefactureerd voor een machine
      die er niet is, en de eerste die het merkt is de klant.
    * Een gast op de node die wij niet kennen. Die eet geheugen en schijf die wij
      denken nog te kunnen verkopen -- de scheduler plaatst er dus overheen --
      en niemand ruimt hem ooit op, omdat er niets naar wijst.

  ## Wat dit NIET doet

  Niets automatisch opruimen. Geen VPS op `:deleted` zetten, geen vreemde gast
  verwijderen. Beide zijn onomkeerbaar en beide berusten op de aanname dat het
  antwoord van de node klopt -- en precies dat is wat hier wordt gecontroleerd.
  Een node die een half antwoord geeft (een hypervisor die traag is, een API die
  een lege lijst teruggeeft) zou dan een vloot wissen.

  Het meldt. Een mens beslist.
  """
  import Ecto.Query

  require Logger

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Notifier
  alias ControlPlane.Repo

  # Hoe vers een heartbeat moet zijn voordat een node werk krijgt. Ruim boven het
  # hartslaginterval van dertig seconden, zodat één gemiste tik niets overslaat.
  @node_levend_seconds 180

  @doc """
  Zet een inventarisatie klaar voor elke online node die er nog geen heeft.

  Geen tweede als er al een openstaat: die zou in de rij achter de eerste
  belanden en hetzelfde antwoord opleveren, en de agent verwerkt commando's één
  voor één.
  """
  @spec request_all() :: non_neg_integer()
  def request_all do
    # Ook hier telt de heartbeat en niet alleen de status. Een node die niet
    # praat haalt zijn commando's niet op, dus zo'n inventarisatie blijft
    # openstaan -- en `open_verzoek?/1` zorgt er dan voor dat die node nooit meer
    # opnieuw wordt gevraagd. Het vangnet dat drift moet opsporen zou zichzelf
    # daarmee uitschakelen voor precies de nodes waar het meest mis kan zijn.
    levend = Clock.shift(-@node_levend_seconds)

    nodes =
      Repo.all(
        from n in Node,
          where:
            n.status in [:online, :draining] and
              not is_nil(n.last_heartbeat_at) and n.last_heartbeat_at >= ^levend,
          select: n.id
      )

    Enum.count(nodes, fn node_id ->
      if open_verzoek?(node_id), do: false, else: match?({:ok, _}, vraag_aan(node_id))
    end)
  end

  defp open_verzoek?(node_id) do
    Repo.exists?(
      from c in Command,
        where:
          c.node_id == ^node_id and c.kind == :inventory and c.status in [:pending, :delivered]
    )
  end

  defp vraag_aan(node_id) do
    %Command{}
    |> Command.changeset(%{node_id: node_id, kind: :inventory, status: :pending, payload: %{}})
    |> Repo.insert()
  end

  @doc """
  Vergelijkt het antwoord van een node met de administratie en meldt de verschillen.

  `guests` is de lijst provider-ids die de node zelf zegt te hebben.
  """
  @spec compare(binary(), [String.t()]) :: %{verdwenen: [map()], onbekend: [String.t()]}
  def compare(node_id, guests) when is_list(guests) do
    op_de_node = MapSet.new(guests)

    volgens_ons =
      Repo.all(
        from v in Vps,
          where:
            v.node_id == ^node_id and not is_nil(v.provider_vm_id) and
              v.status in [:active, :stopped, :paused],
          select: %{id: v.id, naam: v.name, vm_id: v.provider_vm_id, status: v.status}
      )

    verdwenen = Enum.reject(volgens_ons, &MapSet.member?(op_de_node, &1.vm_id))

    van_ons = MapSet.new(volgens_ons, & &1.vm_id)

    onbekend =
      guests
      |> Enum.reject(&MapSet.member?(van_ons, &1))
      |> binnen_ons_bereik(node_id)

    meld(node_id, verdwenen, onbekend)

    %{verdwenen: verdwenen, onbekend: onbekend}
  end

  # Alleen gasten binnen het VMID-bereik dat deze node voor Bunk heeft
  # gereserveerd. Daarbuiten zijn ze per definitie van de operator zelf -- zijn
  # router, zijn eigen machines, de template -- en die melden is geen signaal
  # maar ruis.
  #
  # Dat is niet theoretisch: de eerste draai meldde 21 "onbekende" gasten op een
  # node, en alle 21 waren legitiem van de eigenaar. Elk half uur opnieuw. Een
  # waarschuwing die altijd afgaat is er een die niemand leest, en dan mist hij
  # ook de ene keer dat het wél iets betekent.
  #
  # Geen bereik ingesteld? Dan is er geen grond om iets van de operator "vreemd"
  # te noemen, en zwijgen we over deze richting.
  defp binnen_ons_bereik(ids, node_id) do
    case Repo.one(from n in Node, where: n.id == ^node_id, select: {n.vmid_min, n.vmid_max}) do
      {min, max} when is_integer(min) and is_integer(max) ->
        Enum.filter(ids, &in_bereik?(&1, min, max))

      _ ->
        []
    end
  end

  defp in_bereik?(id, min, max) do
    case Integer.parse(id) do
      {nummer, ""} -> nummer >= min and nummer <= max
      # Een id dat geen nummer is komt van een andere hypervisor (ESXi gebruikt
      # managed-object ids). Daar zegt een VMID-bereik niets over.
      _ -> false
    end
  end

  defp meld(_node_id, [], []), do: :ok

  defp meld(node_id, verdwenen, onbekend) do
    if verdwenen != [] do
      Logger.error(
        "drift op node #{node_id}: #{length(verdwenen)} VPS(en) staan bij ons als draaiend " <>
          "maar bestaan niet op de node: #{Enum.map_join(verdwenen, ", ", & &1.vm_id)}"
      )
    end

    if onbekend != [] do
      # Geen `error`: een vreemde gast is meestal iets van de operator zelf --
      # de template, een eigen machine. Het hoort zichtbaar te zijn, niet
      # alarmerend.
      Logger.warning(
        "drift op node #{node_id}: #{length(onbekend)} gast(en) draaien daar zonder dat wij " <>
          "ze kennen: #{Enum.join(onbekend, ", ")}"
      )
    end

    # Alleen de dure richting mailt. Een vreemde gast kost capaciteit; een VPS
    # die wij factureren en die niet bestaat kost een klant geld.
    if verdwenen != [] do
      Notifier.deliver_operational_alert(
        "#{length(verdwenen)} VPS(en) bestaan niet meer op hun node",
        """
        Deze VPS'en staan in de administratie als draaiend, maar node #{node_id}
        kent hun VM niet:

        #{Enum.map_join(verdwenen, "\n", fn v -> "  #{v.naam} (#{v.status}) — vm #{v.vm_id} — #{v.id}" end)}

        Er wordt NIETS automatisch opgeruimd: dat zou berusten op de aanname dat
        het antwoord van de node klopt, en juist dat is wat hier gecontroleerd
        wordt. Kijk eerst op de node zelf voordat je iets verwijdert.

        Zolang ze als draaiend in de administratie staan, worden ze gefactureerd.
        """
      )
    end

    :ok
  end
end
