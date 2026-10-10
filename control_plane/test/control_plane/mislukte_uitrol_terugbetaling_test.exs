defmodule ControlPlane.MislukteUitrolTerugbetalingTest do
  @moduledoc """
  Wat een klant terugkrijgt als zijn uitrol mislukt.

  Het bedrag hoort uit het grootboek te komen en niet uit de prijs van het
  pakket of van het abonnement. Dat klinkt als een detail en is het niet: die
  drie getallen lopen uiteen zodra iemand korting heeft gekregen of het pakket
  intussen anders geprijsd is. Dan betaalt het platform te veel of te weinig
  terug, en in beide gevallen klopt de administratie niet meer met de
  werkelijkheid.

  Daarnaast moet de oorspronkelijke afschrijving als teruggeboekt worden
  gemarkeerd. Gebeurt dat niet, dan blijft er een openstaande `vps_charge` staan
  die een latere sweep nóg een keer kan terugboeken.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
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

    %{user: user, region: region, node: node}
  end

  test "de klant krijgt terug wat er is afgeschreven, niet wat het pakket kost" do
    %{user: user, region: region} = opstelling()
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

    # De werkelijke afschrijving voor deze VPS. Dit is het getal dat terug moet,
    # wat de catalogus er verder ook van vindt.
    {:ok, afschrijving} =
      Credits.add_entry(user.id, -1234, "vps_charge", "Eerste maand", vps.id)

    saldo_na_afschrijving = Credits.balance_cents(user.id)

    {:ok, _} =
      Provisioning.apply_result(command, %{
        "status" => "failed",
        "error" => "clone mislukt"
      })

    assert Credits.balance_cents(user.id) == saldo_na_afschrijving + 1234
    assert Repo.get!(Vps, vps.id).status == :failed

    # En de oorspronkelijke regel is gemarkeerd, zodat geen enkele sweep hem nog
    # een tweede keer terugboekt.
    assert Repo.get!(LedgerEntry, afschrijving.id).kind == "vps_charge_refunded"
  end

  test "zonder afschrijving wordt er niets teruggeboekt" do
    # Een VPS die intern is aangemaakt zonder dat er iemand voor betaald heeft.
    # De abonnementsprijs terugbetalen zou hier geld geven dat nooit is betaald.
    %{user: user, region: region} = opstelling()
    {:ok, _} = Credits.add_entry(user.id, 10_000, "admin_adjustment", "startsaldo")

    {:ok, %{vps: vps, command: command}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: "intern",
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 10,
        owner_id: user.id,
        owner_email: user.email,
        template_id: 9000
      })

    saldo_vooraf = Credits.balance_cents(user.id)

    {:ok, _} =
      Provisioning.apply_result(command, %{"status" => "failed", "error" => "geen sjabloon"})

    assert Credits.balance_cents(user.id) == saldo_vooraf
    assert Repo.get!(Vps, vps.id).status == :failed
    assert Repo.aggregate(from(c in Command, where: c.vps_id == ^vps.id), :count) >= 1
  end
end
