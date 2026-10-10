defmodule ControlPlane.VastgelopenToestandenTest do
  @moduledoc """
  Toestanden waar een VPS vanzelf weer uit komt, ook als de node nooit meer
  iets meldt.

  `:restoring` en een uitgestelde `:deleting` werden alleen verlaten via een
  resultaat van de agent. Kwam dat nooit, dan stond de VPS voorgoed op
  "terugzetten" of "wordt verwijderd", met elke knop geblokkeerd of de
  capaciteit geboekt.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning

  defp node_met(status) do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
      |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{status: status, last_heartbeat_at: Clock.now()})
    |> Repo.insert!()
  end

  defp vps_op(node, status, geleden \\ 0) do
    t = Clock.shift(-geleden)

    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: node.region_id,
      node_id: node.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      provider_vm_id: "131"
    })
    |> Ecto.Changeset.change(%{status: status, inserted_at: t, updated_at: t})
    |> Repo.insert!()
  end

  defp commando(vps, kind, geleden) do
    t = Clock.shift(-geleden)

    Repo.insert!(%Command{
      node_id: vps.node_id,
      vps_id: vps.id,
      kind: kind,
      status: :delivered,
      delivered_at: t,
      payload: %{},
      inserted_at: t,
      updated_at: t
    })
  end

  defp status(%Vps{id: id}), do: Repo.get!(Vps, id).status

  test "een terugzetactie die zes uur niets meldt, wordt afgesloten op :stopped" do
    vps = vps_op(node_met(:online), :restoring)
    cmd = commando(vps, :restore_backup, 7 * 3600)

    assert Provisioning.fail_stuck_restores() == 1
    # :stopped en niet :active: de schijf kan half geschreven zijn.
    assert status(vps) == :stopped
    assert Repo.get!(Command, cmd.id).status == :failed
  end

  test "een terugzetactie die net loopt, blijft staan" do
    vps = vps_op(node_met(:online), :restoring)
    commando(vps, :restore_backup, 600)

    assert Provisioning.fail_stuck_restores() == 0
    assert status(vps) == :restoring
  end

  test "een VPS op :restoring zonder lopend commando komt vrij" do
    # Niets zal hem ooit nog verplaatsen.
    vps = vps_op(node_met(:online), :restoring, 3600)

    assert Provisioning.fail_stuck_restores() == 1
    assert status(vps) == :stopped
  end

  test "een uitgestelde verwijdering op een verdwenen node blijft niet hangen" do
    # De klant verwijderde terwijl de uitrol liep; de node viel daarna weg.
    vps = vps_op(node_met(:offline), :deleting)
    commando(vps, :provision, 3600)

    assert Provisioning.fail_stuck_provisioning_vpses() == 1
    refute status(vps) == :deleting
  end
end
