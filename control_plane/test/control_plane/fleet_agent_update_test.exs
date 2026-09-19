defmodule ControlPlane.FleetAgentUpdateTest do
  @moduledoc """
  De uitrol van een nieuwe agentbinary gaat in golven.

  Eerst één node als kanarie; pas als die zich met de nieuwe versie terugmeldt
  volgt de rest. Blijft hij weg, dan stopt de uitrol en blijft de fleet op de
  oude binary staan — dat is de hele reden dat dit niet meer alles-in-een-keer
  gebeurt.
  """
  use ControlPlane.DataCase, async: false

  import Ecto.Query

  alias ControlPlane.Fleet.AgentUpdate
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  @doel "abc1234"

  setup do
    vorige = Application.get_env(:control_plane, :build_version)
    Application.put_env(:control_plane, :build_version, @doel)
    on_exit(fn -> restore(vorige) end)

    %{
      regio: Repo.insert!(%Region{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
    }
  end

  defp restore(nil), do: Application.delete_env(:control_plane, :build_version)
  defp restore(v), do: Application.put_env(:control_plane, :build_version, v)

  # Een verse heartbeat hoort erbij, ook al gaat geen van deze tests erover.
  #
  # `:online` zonder heartbeat bestaat in productie niet: `mark_stale_nodes_offline/1`
  # zet zo'n node op `:offline`. Een fixture die dat wel doet beschrijft een
  # toestand die niet voorkomt, en dan testen deze tests iets anders dan ze
  # denken -- de uitrol slaat een node die niet meer praat namelijk over, want
  # die haalt zijn commando's toch niet op.
  defp fleet_node(regio, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Node{
          name: "node-#{System.unique_integer([:positive])}",
          region_id: regio.id,
          hypervisor: :proxmox,
          status: :online,
          last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
  end

  defp updates(node_id) do
    Repo.all(from c in Command, where: c.node_id == ^node_id and c.kind == :update)
  end

  defp alle_updates do
    Repo.all(from c in Command, where: c.kind == :update, select: c.node_id)
  end

  defp afronden(node, versie) do
    Repo.update_all(
      from(c in Command, where: c.node_id == ^node.id and c.kind == :update),
      set: [status: :done]
    )

    node |> Ecto.Changeset.change(agent_version: versie) |> Repo.update!()
  end

  test "de eerste golf is één node, ook als er vier achterlopen", %{regio: r} do
    for _ <- 1..4, do: fleet_node(r)

    assert {:dispatched, 1} = AgentUpdate.dispatch_wave()
    assert length(alle_updates()) == 1
  end

  test "zolang de kanarie niets meldt gebeurt er niets", %{regio: r} do
    for _ <- 1..3, do: fleet_node(r)
    assert {:dispatched, 1} = AgentUpdate.dispatch_wave()

    # Dit is de kern: een tweede tik mag de rest niet alsnog meesleuren.
    assert :waiting = AgentUpdate.dispatch_wave()
    assert :waiting = AgentUpdate.dispatch_wave()
    assert length(alle_updates()) == 1
  end

  test "zodra de kanarie draait volgt de rest in groepen van twee", %{regio: r} do
    nodes = for _ <- 1..4, do: fleet_node(r)

    assert {:dispatched, 1} = AgentUpdate.dispatch_wave()
    [kanarie_id] = alle_updates()
    kanarie = Enum.find(nodes, &(&1.id == kanarie_id))
    afronden(kanarie, @doel)

    assert {:dispatched, 2} = AgentUpdate.dispatch_wave()
    assert :waiting = AgentUpdate.dispatch_wave()
  end

  test "een node die de doelversie al draait krijgt niets", %{regio: r} do
    fleet_node(r, %{agent_version: @doel})
    achter = fleet_node(r)

    assert {:dispatched, 1} = AgentUpdate.dispatch_wave()
    assert [_] = updates(achter.id)
  end

  test "is de hele fleet bij, dan is er niets te doen", %{regio: r} do
    fleet_node(r, %{agent_version: @doel})
    fleet_node(r, %{agent_version: @doel})

    assert :up_to_date = AgentUpdate.dispatch_wave()
    assert alle_updates() == []
  end

  test "offline nodes blijven buiten de uitrol", %{regio: r} do
    uit = fleet_node(r, %{status: :offline})
    assert :up_to_date = AgentUpdate.dispatch_wave()
    assert updates(uit.id) == []
  end

  test "een node die leegloopt telt wel mee", %{regio: r} do
    leeg = fleet_node(r, %{status: :draining})
    assert {:dispatched, 1} = AgentUpdate.dispatch_wave()
    assert [_] = updates(leeg.id)
  end

  test "een kanarie die vastloopt stopt de uitrol en meldt dat", %{regio: r} do
    for _ <- 1..3, do: fleet_node(r)
    assert {:dispatched, 1} = AgentUpdate.dispatch_wave()

    # Terug in de tijd: het commando staat er langer dan het geduld toelaat.
    Repo.update_all(
      from(c in Command, where: c.kind == :update),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
    )

    assert :stalled = AgentUpdate.dispatch_wave()

    # En de rest blijft staan waar hij stond. Dat is het punt van een kanarie:
    # liever een fleet op een oude binary dan een fleet op een kapotte.
    assert length(alle_updates()) == 1
  end

  test "zonder versiestempel doet de uitrol niets", %{regio: r} do
    Application.delete_env(:control_plane, :build_version)
    fleet_node(r)

    # Er is dan niets om "klaar" aan af te lezen. Blind versturen zou elke tik
    # opnieuw een commando opleveren; de nachtelijke timer op de node vangt dit.
    assert :no_target = AgentUpdate.dispatch_wave()
    assert alle_updates() == []
  end
end
