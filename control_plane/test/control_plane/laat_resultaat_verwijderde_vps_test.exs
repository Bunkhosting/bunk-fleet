defmodule ControlPlane.LaatResultaatVerwijderdeVpsTest do
  @moduledoc """
  Een uitrolresultaat dat binnenkomt nadat de VPS al verwijderd is.

  `:deleted` is een eindstation. Zette een laat resultaat hem terug op
  `:failed`, dan kwam hij terug in de lijst van de klant en in de quotumtelling,
  en liep het terugbetaal-en-vrijgeefpad voor een machine die al was afgesloten.
  Het commando zelf moet wel afgerond worden, anders levert de agent het
  resultaat eindeloos opnieuw af.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning

  defp opstelling do
    user = confirmed_user_fixture()
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: region.id
      })
      |> Ecto.Changeset.change(%{
        status: :online,
        last_heartbeat_at: ControlPlane.Clock.now(),
        total_vcpu: 32,
        total_ram_mb: 65_536,
        total_disk_gb: 1000,
        available_vcpu: 32,
        available_ram_mb: 65_536,
        available_disk_gb: 1000
      })
      |> Repo.insert!()

    {:ok, _} = Credits.add_entry(user.id, 10_000, "admin_adjustment", "startsaldo")

    {:ok, %{vps: vps, command: command}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: "web",
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 10,
        owner_id: user.id,
        owner_email: user.email,
        template_id: 9000
      })

    {:ok, _} = Credits.add_entry(user.id, -1234, "vps_charge", "Eerste maand", vps.id)

    %{user: user, node: node, vps: vps, command: command}
  end

  # De VPS is weg terwijl zijn uitrolcommando nog openstaat -- de toestand
  # waarin een laat resultaat hem vroeger terugzette. De housekeeping geeft de
  # vastgehouden reservering daarna één keer vrij, zoals in productie.
  defp verwijder(%Vps{} = vps) do
    vps |> Ecto.Changeset.change(status: :deleted) |> Repo.update!()
    assert Fleet.release_orphaned_reservations() >= 1
  end

  defp grootboekregels(user) do
    Repo.aggregate(from(e in LedgerEntry, where: e.user_id == ^user.id), :count)
  end

  defp capaciteit(node) do
    n = Repo.get!(Node, node.id)
    {n.available_vcpu, n.available_ram_mb, n.available_disk_gb}
  end

  defp reserveringen(vps) do
    Repo.all(from r in Reservation, where: r.vps_id == ^vps.id, select: {r.id, r.status})
  end

  defp deletes_voor(node) do
    Repo.all(from c in Command, where: c.node_id == ^node.id and c.kind == :delete)
  end

  test "een laat mislukt-resultaat laat een verwijderde VPS verwijderd en beweegt niets" do
    %{user: user, node: node, vps: vps, command: command} = opstelling()
    verwijder(vps)

    regels = grootboekregels(user)
    saldo = Credits.balance_cents(user.id)
    vrij = capaciteit(node)
    gereserveerd = reserveringen(vps)

    assert {:ok, _} =
             Provisioning.apply_result(command, %{"status" => "failed", "error" => "clone"})

    assert Repo.get!(Vps, vps.id).status == :deleted
    # Afgerond, dus geen herlevering.
    assert Repo.get!(Command, command.id).status == :failed

    assert grootboekregels(user) == regels
    assert Credits.balance_cents(user.id) == saldo
    assert capaciteit(node) == vrij
    assert reserveringen(vps) == gereserveerd
    # Zonder vm_id is er niets om af te breken.
    assert deletes_voor(node) == []
  end

  test "een laat mislukt-resultaat met vm_id ruimt die VM op" do
    %{node: node, vps: vps, command: command} = opstelling()
    verwijder(vps)

    assert {:ok, _} =
             Provisioning.apply_result(command, %{
               "status" => "failed",
               "vm_id" => "707",
               "error" => "half gebouwd"
             })

    assert Repo.get!(Vps, vps.id).status == :deleted
    assert [delete] = deletes_voor(node)
    assert delete.payload["vm_id"] == "707"
    assert delete.status == :pending
  end

  test "een laat klaar-resultaat met vm_id laat de VPS verwijderd en breekt de VM af" do
    %{user: user, node: node, vps: vps, command: command} = opstelling()
    verwijder(vps)

    regels = grootboekregels(user)
    vrij = capaciteit(node)

    assert {:ok, _} =
             Provisioning.apply_result(command, %{
               "status" => "done",
               "vm_id" => "4321",
               "ip" => "10.10.0.30"
             })

    herladen = Repo.get!(Vps, vps.id)
    assert herladen.status == :deleted
    assert herladen.provider_vm_id == "4321"
    assert Repo.get!(Command, command.id).status == :done

    assert [delete] = deletes_voor(node)
    assert delete.payload["vm_id"] == "4321"
    assert delete.vps_id == vps.id
    assert delete.status == :pending

    assert grootboekregels(user) == regels
    assert capaciteit(node) == vrij
  end

  test "tegenproef: een lopende uitrol die mislukt gaat naar :failed, met terugbetaling" do
    %{user: user, node: node, vps: vps, command: command} = opstelling()
    assert Repo.get!(Vps, vps.id).status == :provisioning

    saldo = Credits.balance_cents(user.id)
    {vcpu, ram, disk} = capaciteit(node)

    assert {:ok, _} =
             Provisioning.apply_result(command, %{"status" => "failed", "error" => "clone"})

    assert Repo.get!(Vps, vps.id).status == :failed
    assert Repo.get!(Command, command.id).status == :failed
    assert Credits.balance_cents(user.id) == saldo + 1234

    reservering = Repo.get_by!(Reservation, vps_id: vps.id)
    assert reservering.status == :released

    assert capaciteit(node) ==
             {vcpu + reservering.vcpu, ram + reservering.ram_mb, disk + reservering.disk_gb}
  end
end
