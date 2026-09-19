defmodule ControlPlane.CommandoAfleverTellerTest do
  use ControlPlane.DataCase, async: true

  import Ecto.Query

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  # Zelfde opzet als commando_opruimen_test: een node heeft een regio nodig, en
  # `node` als naam botst met Kernel.node/0.
  defp fleet_node do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Repo.insert!()
  end

  # Herlevering is goed: een agent die halverwege omvalt hoort zijn werk terug te
  # krijgen. Maar zonder bovengrens herhaalt een commando waarvan alleen het
  # TERUGMELDEN faalt zich elke 90 seconden, eeuwig, terwijl de VPS bij de klant
  # in "aanmaken" staat en op de node allang draait.

  defp commando(node, attrs \\ %{}) do
    %Command{}
    |> Command.changeset(
      Map.merge(
        %{kind: :provision, payload: %{}, node_id: node.id, status: :pending},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp verouder(cmd) do
    oud = Clock.shift(-600)

    Repo.update_all(from(c in Command, where: c.id == ^cmd.id),
      set: [delivered_at: oud, updated_at: oud]
    )

    Repo.get!(Command, cmd.id)
  end

  test "elke aflevering telt op" do
    node = fleet_node()
    cmd = commando(node)

    assert Repo.get!(Command, cmd.id).delivery_count == 0

    Provisioning.mark_delivered_all([cmd])
    assert Repo.get!(Command, cmd.id).delivery_count == 1

    Provisioning.mark_delivered_all([cmd])
    assert Repo.get!(Command, cmd.id).delivery_count == 2
  end

  test "boven de grens wordt een commando niet meer uitgedeeld" do
    node = fleet_node()
    cmd = commando(node)

    for _ <- 1..Provisioning.max_afleveringen() do
      Provisioning.mark_delivered_all([cmd])
      verouder(cmd)
    end

    assert Provisioning.deliverable_commands_for_node(node) == []
  end

  test "en dan staat hij in de lijst die gemeld wordt" do
    node = fleet_node()
    cmd = commando(node)

    for _ <- 1..Provisioning.max_afleveringen() do
      Provisioning.mark_delivered_all([cmd])
    end

    vast = Provisioning.vastgelopen_commandos()
    assert Enum.any?(vast, &(&1.id == cmd.id))
  end

  test "een commando dat gewoon antwoordt haalt de grens nooit" do
    node = fleet_node()
    cmd = commando(node)

    Provisioning.mark_delivered_all([cmd])
    verouder(cmd)

    assert Provisioning.deliverable_commands_for_node(node) |> Enum.map(& &1.id) == [cmd.id]
    assert Provisioning.vastgelopen_commandos() == []
  end
end
