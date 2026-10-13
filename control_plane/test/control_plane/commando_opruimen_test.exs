defmodule ControlPlane.CommandoOpruimenTest do
  @moduledoc """
  Afgehandelde commando's verdwijnen na verloop van tijd; werk dat nog openstaat
  niet, hoe oud het ook is.

  Dat tweede is de eigenlijke reden dat deze test bestaat. Een opruimer die op
  ouderdom alleen kijkt, wist precies de rijen die je nodig hebt: een commando
  dat al weken :pending is, is geen rommel maar een node die niets ophaalt.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Provisioning.CommandQueue

  defp fleet_node do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Repo.insert!()
  end

  defp commando(node, status, dagen_oud) do
    toen = Clock.shift(-dagen_oud * 24 * 3600)

    %Command{}
    |> Command.changeset(%{node_id: node.id, kind: :inventory, status: status})
    |> Repo.insert!()
    |> Ecto.Changeset.change(%{inserted_at: toen, updated_at: toen})
    |> Repo.update!()
  end

  test "oude afgehandelde commando's gaan weg, verse blijven" do
    node = fleet_node()
    oud = commando(node, :done, 200)
    vers = commando(node, :done, 3)

    assert CommandQueue.purge_old_commands(90) == 1
    refute Repo.get(Command, oud.id)
    assert Repo.get(Command, vers.id)
  end

  test "werk dat nog openstaat blijft staan, ook als het stokoud is" do
    node = fleet_node()
    wacht = commando(node, :pending, 400)
    onderweg = commando(node, :delivered, 400)

    assert CommandQueue.purge_old_commands(90) == 0
    assert Repo.get(Command, wacht.id)
    assert Repo.get(Command, onderweg.id)
  end

  test "er gaan er niet meer weg dan de bovengrens per ronde" do
    # Bij de eerste keer opruimen kunnen er honderdduizenden staan. Die in één
    # transactie wissen houdt een lock vast terwijl klanten op hun paneel zitten.
    node = fleet_node()
    for _ <- 1..5, do: commando(node, :failed, 120)

    assert CommandQueue.purge_old_commands(90, 2) == 2
    assert CommandQueue.purge_old_commands(90, 2) == 2
    assert CommandQueue.purge_old_commands(90, 2) == 1
    assert CommandQueue.purge_old_commands(90, 2) == 0
  end
end
