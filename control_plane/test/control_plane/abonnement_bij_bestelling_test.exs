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

  defp bestel(user, region, pakket) do
    Provisioning.create_vps_for_owner(user, %{
      region_id: region.id,
      name: "v-#{System.unique_integer([:positive])}",
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20,
      template_id: 9000,
      package_id: pakket.id
    })
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
end
