defmodule ControlPlane.ProvisioningBandbreedteTest do
  @moduledoc """
  De snelheid van het pakket moet de node bereiken.

  Dit ontbrak, en daardoor kon het volgende maandenlang waar zijn zonder dat
  iemand het zag: `vps_changeset/1` liet `package_id` vallen, dus stond er op
  elke VPS `package_id = NULL`, dus gaf `snelheid_van_pakket/1` altijd nil, dus
  stond er in geen enkele provision-opdracht een `rate_mbit`. De pakketten
  beloofden 200, 500 en 1000 Mbit en er is er nooit één afgedwongen.

  Er waren tests voor het pakket, voor de prijs en voor de opdracht -- maar geen
  enkele die de héle keten nalas. Daarom gaat deze test bewust over de keten en
  niet over een functie: van "klant bestelt dit pakket" tot "dit staat er in de
  opdracht die de node krijgt".
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  defp opzet(mbit) do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
      |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "pve-test", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now(),
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000,
      reported_avail_vcpu: 32,
      reported_avail_ram_mb: 65_536,
      reported_avail_disk_gb: 1000
    })
    |> Repo.insert!()

    pakket =
      %Package{}
      |> Package.changeset(%{
        name: "Test #{System.unique_integer([:positive])}",
        cpu_cores: 1,
        ram_gb: 1,
        disk_gb: 20,
        price_monthly: "3.99",
        bandwidth_mbit: mbit
      })
      |> Repo.insert!()

    {region, pakket}
  end

  defp bestel(region, pakket) do
    {:ok, %{vps: vps, command: %Command{payload: payload}}} =
      Provisioning.create_vps(%{
        name: "snelheidstest",
        region_id: region.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20,
        owner_email: "klant@voorbeeld.nl",
        package_id: pakket.id
      })

    {vps, payload}
  end

  test "het pakket wordt op de VPS vastgelegd" do
    {region, pakket} = opzet(500)
    {vps, _payload} = bestel(region, pakket)

    # Dit was de fout: het veld kwam wél binnen en werd stil weggelaten.
    assert Repo.get!(Vps, vps.id).package_id == pakket.id
  end

  test "de snelheid van het pakket staat in de opdracht voor de node" do
    {region, pakket} = opzet(500)
    {_vps, payload} = bestel(region, pakket)

    assert payload["rate_mbit"] == 500
  end

  test "een ander pakket levert een andere snelheid op" do
    {region, pakket} = opzet(1000)
    {_vps, payload} = bestel(region, pakket)

    assert payload["rate_mbit"] == 1000
  end

  test "zonder pakket komt er geen verzonnen limiet in de opdracht" do
    {region, _pakket} = opzet(500)

    {:ok, %{command: %Command{payload: payload}}} =
      Provisioning.create_vps(%{
        name: "geen-pakket",
        region_id: region.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20,
        owner_email: "klant@voorbeeld.nl"
      })

    # De sleutel staat er wel, met nil erin -- de agent leest dat als "geen
    # limiet" en laat de netwerkkaart met rust. Waar het om gaat is dat er geen
    # getal wordt verzonnen wanneer er geen pakket bij hoort.
    assert payload["rate_mbit"] == nil
  end
end
