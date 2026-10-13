defmodule ControlPlane.FleetReclaimTest do
  @moduledoc "Reclaiming orphaned/stale capacity reservations so nodes free up."
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Housekeeping
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Vps

  defp setup_node do
    region =
      %Region{}
      |> Region.changeset(%{code: "rc-#{System.unique_integer([:positive])}", name: "R"})
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Ecto.Changeset.change(%{
        status: :online,
        total_vcpu: 8,
        total_ram_mb: 16_384,
        total_disk_gb: 200,
        available_vcpu: 0,
        available_ram_mb: 12_288,
        available_disk_gb: 120
      })
      |> Repo.insert!()

    {region, node}
  end

  defp vps(region, node, status) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: region.id,
      node_id: node.id,
      vcpu: 4,
      ram_mb: 4096,
      disk_gb: 80
    })
    |> Ecto.Changeset.put_change(:status, status)
    |> Repo.insert!()
  end

  defp held(node, vps_id) do
    %Reservation{}
    |> Reservation.changeset(%{
      node_id: node.id,
      vps_id: vps_id,
      vcpu: 4,
      ram_mb: 4096,
      disk_gb: 80,
      status: :held
    })
    |> Repo.insert!()
  end

  test "reclaims an orphaned (null vps_id) reservation and restores node capacity" do
    {_region, node} = setup_node()
    held(node, nil)

    assert Housekeeping.release_orphaned_reservations() == 1
    n = Repo.get!(Node, node.id)
    assert n.available_vcpu == 4
    assert n.available_ram_mb == 12_288 + 4096
    assert n.available_disk_gb == 120 + 80
    assert [%Reservation{status: :released}] = Repo.all(Reservation)
  end

  test "reclaims a deleted VPS's reservation but keeps a provisioning VPS's" do
    {region, node} = setup_node()
    deleted = vps(region, node, :deleted)
    live = vps(region, node, :provisioning)
    held(node, deleted.id)
    keep = held(node, live.id)

    assert Housekeeping.release_orphaned_reservations() == 1
    assert Repo.get!(Reservation, keep.id).status == :held
    assert Repo.get!(Node, node.id).available_vcpu == 4
  end
end
