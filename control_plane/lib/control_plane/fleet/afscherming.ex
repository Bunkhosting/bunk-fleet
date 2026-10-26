defmodule ControlPlane.Fleet.Afscherming do
  @moduledoc """
  Een melding aan de operator als klanten op één node niet van elkaar zijn
  afgeschermd.

  De agent meldt het in `network_note` als hij het ziet: op Proxmox staat de
  datacenter-firewall uit (dan doen de regels per gast niets), en ESXi schermt
  helemaal niet af. Die notitie neemt een node bewust niet uit verkoop -- het
  is een vermoeden, en een node die daardoor ineens niets meer krijgt is erger
  dan het gat. Maar alleen in het paneel was hij ook te missen, en dat is
  gebeurd: op productie stond de datacenter-firewall uit en niemand wist het.

  Daarom een mail, en alleen als het ertoe doet: als er op die node VPS'en van
  meer dan één klant staan. Met één klant is er niemand om van af te schermen.

  Eén keer per etmaal per node (de reconciler roept dit dagelijks aan). Dit is
  een toestand, geen gebeurtenis: hij blijft tot iemand de firewall aanzet, en
  vaker zeggen maakt hem niet waarder.
  """
  import Ecto.Query

  require Logger

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Notifier
  alias ControlPlane.Repo

  # Beide providers zeggen het in deze woorden; zie `Afscherming` in de agent
  # (proxmox.go en esxi.go). Een notitie over iets anders, zoals een bridge die
  # niet bestaat, bevat ze niet.
  @kenmerk "van elkaar af"

  @doc "Nodes met een afschermingsnotitie waarop VPS'en van meer dan één klant staan."
  @spec te_melden() :: [{Node.t(), pos_integer()}]
  def te_melden do
    Repo.all(
      from n in Node,
        join: v in Vps,
        on: v.node_id == n.id and v.status not in [:deleted, :failed],
        where: n.status in [:online, :draining] and like(n.network_note, ^"%#{@kenmerk}%"),
        group_by: n.id,
        having: count(v.owner_id, :distinct) > 1,
        select: {n, count(v.owner_id, :distinct)}
    )
  end

  @doc "Meldt elke node die eraan toe is; geeft terug hoeveel meldingen er weg zijn."
  @spec melden() :: non_neg_integer()
  def melden do
    Enum.count(te_melden(), fn {node, klanten} ->
      case Notifier.deliver_operational_alert(onderwerp(node), tekst(node, klanten)) do
        :ok ->
          true

        {:error, reden} ->
          Logger.warning(
            "melding over afscherming op #{node.name} niet verstuurd: #{inspect(reden)}"
          )

          false
      end
    end)
  end

  defp onderwerp(%Node{name: naam}), do: "Klanten op #{naam} zijn niet van elkaar afgeschermd"

  defp tekst(%Node{} = node, klanten) do
    """
    Op node #{node.name} staan VPS'en van #{klanten} verschillende klanten, en de agent
    meldt dat ze niet van elkaar zijn afgeschermd:

      #{node.network_note}

    Ze delen één bridge. Wie root heeft op zijn eigen VPS kan dan de VPS'en van de
    anderen bereiken, na ARP-spoofing hun verkeer meelezen en zich voordoen als de
    gateway. De regels per gast staan er wel, maar doen niets zolang de
    datacenter-firewall uit staat.

    Op een Proxmox-node:

      pvesh get /cluster/firewall/options     (enable moet 1 zijn)
      Datacenter > Firewall > Opties > Firewall: Ja

    De node blijft in verkoop. Dit bericht komt eens per dag zolang het zo is.
    """
  end
end
