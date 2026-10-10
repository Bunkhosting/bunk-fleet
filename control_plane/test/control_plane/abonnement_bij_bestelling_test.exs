defmodule ControlPlane.AbonnementBijBestellingTest do
  @moduledoc """
  Een bestelde VPS heeft altijd een abonnement, en een mislukte nooit een
  lopend.

  Het abonnement werd na het plaatsen aangemaakt, buiten elke transactie, en de
  uitkomst werd weggegooid. Viel het proces daartussen weg, dan draaide er een
  VPS die na de eerste maand nooit meer werd gefactureerd. Nu ontstaat het in
  dezelfde transactie als de VPS-rij, en zegt een mislukte plaatsing het weer op.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Subscriptions.Subscription

  setup do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    pakket =
      Repo.insert!(%Package{
        name: "Test",
        cpu_cores: 1,
        ram_gb: 1,
        disk_gb: 20,
        price_monthly: Decimal.new("5.00"),
        is_available: true
      })

    %{region: region, pakket: pakket, user: confirmed_user_fixture()}
  end

  defp node_in(region) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: Clock.now(),
      total_vcpu: 8,
      total_ram_mb: 16_384,
      total_disk_gb: 500,
      available_vcpu: 8,
      available_ram_mb: 16_384,
      available_disk_gb: 500
    })
    |> Repo.insert!()
  end

  defp bestel(user, region, pakket, opts \\ []) do
    Provisioning.create_vps_for_owner(
      user,
      %{
        region_id: region.id,
        name: "v-#{System.unique_integer([:positive])}",
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20,
        template_id: 9000,
        package_id: pakket.id
      },
      opts
    )
  end

  defp afschrijving(user) do
    {:ok, _} = Credits.add_entry(user.id, 1_000, "admin_adjustment", "test")
    {:ok, charge} = Credits.charge(user.id, 500, "vps_charge", "VPS Test")
    charge
  end

  defp abonnement(vps_id), do: Repo.get_by(Subscription, vps_id: vps_id)

  test "een geplaatste VPS heeft een lopend abonnement", %{region: r, pakket: p, user: u} do
    node_in(r)

    assert {:ok, %{vps: vps}} = bestel(u, r, p)
    assert %Subscription{status: :active, owner_id: owner} = abonnement(vps.id)
    assert owner == u.id
  end

  test "een VPS die nergens past, laat geen lopend abonnement achter",
       %{region: r, pakket: p, user: u} do
    # Geen node in deze regio: de plaatsing mislukt na het aanmaken van de rij.
    assert {:error, :no_capacity} = bestel(u, r, p)

    [vps] = Repo.all(from v in Vps, where: v.owner_id == ^u.id)
    assert vps.status == :failed
    assert %Subscription{status: :cancelled} = abonnement(vps.id)
  end

  test "een onbekend pakket levert geen VPS-rij zonder abonnement op",
       %{region: r, user: u} do
    node_in(r)

    # De database weigert een VPS met een pakket dat niet bestaat; dat komt
    # terug als een changeset-fout, niet als een exceptie.
    assert {:error, %Ecto.Changeset{}} = bestel(u, r, %Package{id: 987_654})

    assert Repo.all(from v in Vps, where: v.owner_id == ^u.id) == []
  end

  describe "de afschrijving" do
    # Werd na de aanmaak los gekoppeld. Mislukte dat (een databasehik), dan
    # bestond de VPS terwijl de afschrijving verweesd leek, en betaalde de
    # sweeper hem terug: een gratis VPS.
    test "hangt aan de VPS zodra die bestaat", %{region: r, pakket: p, user: u} do
      node_in(r)
      charge = afschrijving(u)

      assert {:ok, %{vps: vps}} = bestel(u, r, p, afschrijving: charge)
      assert Repo.get!(LedgerEntry, charge.id).vps_id == vps.id

      # En daarom ziet de sweeper hem niet als wees, ook zonder wachttijd.
      assert Credits.refund_orphan_charges(0) == 0
      assert Repo.get!(LedgerEntry, charge.id).kind == "vps_charge"
    end

    test "blijft los als de VPS-rij niet ontstaat", %{region: r, user: u} do
      node_in(r)
      charge = afschrijving(u)

      assert {:error, %Ecto.Changeset{}} =
               bestel(u, r, %Package{id: 987_654}, afschrijving: charge)

      # Teruggedraaid met de rest; de bestelweg betaalt hem dan terug.
      assert Repo.get!(LedgerEntry, charge.id).vps_id == nil
    end
  end
end
