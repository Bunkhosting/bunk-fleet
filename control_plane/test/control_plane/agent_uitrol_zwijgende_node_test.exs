defmodule ControlPlane.AgentUitrolZwijgendeNodeTest do
  use ControlPlane.DataCase, async: false

  import Ecto.Query

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.AgentUpdate
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  # Een node die niet meer heartbeat haalt zijn commando's niet op en kan dus
  # geen update installeren. Hem meetellen als "de uitrol loopt nog" betekent dat
  # één machine die uit staat de hele fleet op de oude binary houdt -- en dat is
  # precies wat er op productie gebeurde: een node die een dag stil was hield
  # drie builds tegen.

  setup do
    oud = Application.get_env(:control_plane, :build_version)
    Application.put_env(:control_plane, :build_version, "nieuw123")
    on_exit(fn -> Application.put_env(:control_plane, :build_version, oud) end)
    :ok
  end

  defp fleet_node(attrs) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: region.id
      })
      |> Repo.insert!()

    Repo.update_all(from(n in Node, where: n.id == ^node.id), set: Map.to_list(attrs))
    Repo.get!(Node, node.id)
  end

  test "een zwijgende node houdt de uitrol niet tegen" do
    stil =
      fleet_node(%{
        status: :draining,
        agent_version: "oud",
        last_heartbeat_at: Clock.shift(-86_400)
      })

    levend =
      fleet_node(%{status: :online, agent_version: "oud", last_heartbeat_at: Clock.now()})

    # De stille node heeft al een update klaarstaan die hij nooit ophaalt.
    %Command{}
    |> Command.changeset(%{node_id: stil.id, kind: :update, status: :pending})
    |> Repo.insert!()

    # Toch gaat de uitrol door, en wel naar de node die nog leeft.
    assert {:dispatched, 1} = AgentUpdate.dispatch_wave()

    klaargezet =
      Repo.all(from c in Command, where: c.kind == :update, select: c.node_id) |> Enum.sort()

    assert levend.id in klaargezet
  end

  test "het commando van de zwijgende node blijft staan voor als hij terugkomt" do
    stil =
      fleet_node(%{status: :online, agent_version: "oud", last_heartbeat_at: Clock.shift(-86_400)})

    cmd =
      %Command{}
      |> Command.changeset(%{node_id: stil.id, kind: :update, status: :pending})
      |> Repo.insert!()

    AgentUpdate.dispatch_wave()

    # Niets weggegooid: hij haalt het op zodra hij weer praat.
    assert Repo.get!(Command, cmd.id).status == :pending
  end

  test "een levende node die blijft hangen stopt de uitrol nog steeds" do
    hangt =
      fleet_node(%{status: :online, agent_version: "oud", last_heartbeat_at: Clock.now()})

    oud = Clock.shift(-3600)

    %Command{}
    |> Command.changeset(%{node_id: hangt.id, kind: :update, status: :delivered})
    |> Repo.insert!()
    |> Ecto.Changeset.change(%{inserted_at: oud})
    |> Repo.update!()

    # Dit is het geval waarvoor de kanarie bestaat: hij leeft, hij praat, en hij
    # komt niet terug met de nieuwe versie. Dan hoort de rest te wachten.
    assert :stalled = AgentUpdate.dispatch_wave()
  end
end
