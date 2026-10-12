defmodule ControlPlane.AfbraakRaceTest do
  @moduledoc """
  De race tussen een slagende uitrol en het afsluiten van een VPS zonder VM.

  `cancel_and_release` besliste op een VPS-struct die vóór zijn sloten gelezen
  was. Committe een provision-done net daarvoor, dan zette hij een VPS die al
  `:active` was, met een VM erop, toch op `:deleted`: een draaiende VM die
  niemand meer opruimt.

  Een echte race is in een test niet te regelen. Hier wordt hij nagebootst door
  de struct te lezen, daarna de rij te veranderen zoals `apply_result/2` dat zou
  doen, en dan het afbreekpad met de verouderde struct aan te roepen.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning.Teardown

  setup do
    user = confirmed_user_fixture()
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()

    fleet_node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Ecto.Changeset.change(%{
        status: :online,
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    %{user: user, region: region, fleet_node: fleet_node}
  end

  # Een VPS die op een node geplaatst is, capaciteit vasthoudt en een uitrol in
  # de wachtrij heeft, maar nog geen VM. Precies wat teardown_unprovisioned/1
  # zonder lopende uitrol naar cancel_and_release stuurt.
  defp geplaatste_vps(ctx, status) do
    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "v-#{System.unique_integer([:positive])}",
        region_id: ctx.region.id,
        node_id: ctx.fleet_node.id,
        owner_id: ctx.user.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 10
      })
      |> Ecto.Changeset.put_change(:status, status)
      |> Repo.insert!()

    %Reservation{}
    |> Reservation.changeset(%{
      node_id: vps.node_id,
      vps_id: vps.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :held
    })
    |> Repo.insert!()

    uitrol =
      %Command{}
      |> Command.changeset(%{
        node_id: vps.node_id,
        vps_id: vps.id,
        kind: :provision,
        status: :pending,
        payload: %{}
      })
      |> Repo.insert!()

    {:ok, _} = Credits.add_entry(ctx.user.id, 10_000, "admin_adjustment", "startsaldo")

    {:ok, afschrijving} =
      Credits.add_entry(ctx.user.id, -1234, "vps_charge", "Eerste maand", vps.id)

    %{vps: vps, uitrol: uitrol, afschrijving: afschrijving}
  end

  # Wat apply_result/2 bij een geslaagde uitrol committeert, buiten de
  # afbraak om: VPS actief met VM, uitrol klaar, reservering vastgelegd.
  defp uitrol_slaagt(%{vps: vps, uitrol: uitrol}, vm_id, vps_status) do
    vps_rij = from(v in Vps, where: v.id == ^vps.id)
    Repo.update_all(vps_rij, set: [status: vps_status, provider_vm_id: vm_id])

    uitrol_rij = from(c in Command, where: c.id == ^uitrol.id)
    Repo.update_all(uitrol_rij, set: [status: :done])

    reservering_rij = from(r in Reservation, where: r.vps_id == ^vps.id)
    Repo.update_all(reservering_rij, set: [status: :committed])
  end

  defp deletes(vps_id) do
    Repo.all(from c in Command, where: c.vps_id == ^vps_id and c.kind == :delete)
  end

  defp reservering(vps_id), do: Repo.one!(from r in Reservation, where: r.vps_id == ^vps_id)

  defp terugbetalingen(vps_id) do
    Repo.all(
      from l in LedgerEntry,
        where: l.vps_id == ^vps_id and l.kind in ["vps_refund", "vps_charge_refunded"]
    )
  end

  defp vm_id, do: "#{1000 + System.unique_integer([:positive])}"

  test "een net geslaagde uitrol krijgt een delete met vm_id, geen stille :deleted", ctx do
    opzet = geplaatste_vps(ctx, :provisioning)
    verouderd = Repo.get!(Vps, opzet.vps.id)
    id = vm_id()

    uitrol_slaagt(opzet, id, :active)

    # Het pad moet echt gehaald zijn: de verouderde struct heeft geen VM en
    # stuurt dus naar teardown_unprovisioned/1 en cancel_and_release.
    assert %Vps{status: :provisioning, provider_vm_id: nil} = verouderd

    assert {:ok, %{vps: %Vps{status: :deleting}, command: %Command{} = delete}} =
             Teardown.afbreken(verouderd)

    assert %Command{kind: :delete, status: :pending, payload: %{"vm_id" => ^id}} = delete
    assert delete.node_id == ctx.fleet_node.id

    assert %Vps{status: :deleting, provider_vm_id: ^id} = Repo.get!(Vps, opzet.vps.id)
    assert [%Command{payload: %{"vm_id" => ^id}}] = deletes(opzet.vps.id)

    # De capaciteit blijft geboekt tot de delete klaar meldt, en er gaat geen
    # geld terug voor een machine die draait.
    assert reservering(opzet.vps.id).status == :committed
    assert terugbetalingen(opzet.vps.id) == []
    assert Repo.get!(LedgerEntry, opzet.afschrijving.id).kind == "vps_charge"
    assert Repo.get!(Command, opzet.uitrol.id).status == :done
  end

  test "een uitgestelde afbraak met net geslaagde uitrol houdt zijn delete", ctx do
    # De VPS stond al op :deleting zonder VM. Slaagt de uitrol, dan houdt
    # Results hem op :deleting, legt het vm_id vast en zet de delete klaar.
    opzet = geplaatste_vps(ctx, :deleting)
    verouderd = Repo.get!(Vps, opzet.vps.id)
    id = vm_id()

    uitrol_slaagt(opzet, id, :deleting)

    %Command{}
    |> Command.changeset(%{
      node_id: ctx.fleet_node.id,
      vps_id: opzet.vps.id,
      kind: :delete,
      status: :pending,
      payload: %{"vm_id" => id}
    })
    |> Repo.insert!()

    assert {:error, :already_deleting} = Teardown.afbreken(verouderd)

    assert %Vps{status: :deleting, provider_vm_id: ^id} = Repo.get!(Vps, opzet.vps.id)
    assert [%Command{status: :pending, payload: %{"vm_id" => ^id}}] = deletes(opzet.vps.id)
    assert reservering(opzet.vps.id).status == :committed
    assert terugbetalingen(opzet.vps.id) == []
  end

  test "tegenproef: zonder tussenliggende uitrol sluit hij af zoals altijd", ctx do
    opzet = geplaatste_vps(ctx, :provisioning)
    verouderd = Repo.get!(Vps, opzet.vps.id)

    assert {:ok, %{vps: %Vps{status: :deleted}, command: nil}} = Teardown.afbreken(verouderd)

    assert Repo.get!(Vps, opzet.vps.id).status == :deleted
    assert deletes(opzet.vps.id) == []
    assert reservering(opzet.vps.id).status == :released
    assert Repo.get!(Command, opzet.uitrol.id).status == :failed
  end

  test "tegenproef: een uitgestelde afbraak zonder uitrol meer sluit hij ook af", ctx do
    opzet = geplaatste_vps(ctx, :deleting)
    verouderd = Repo.get!(Vps, opzet.vps.id)

    assert {:ok, %{vps: %Vps{status: :deleted}, command: nil}} = Teardown.afbreken(verouderd)

    assert deletes(opzet.vps.id) == []
    assert reservering(opzet.vps.id).status == :released
  end
end
