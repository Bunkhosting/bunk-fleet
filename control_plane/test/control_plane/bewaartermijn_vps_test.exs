defmodule ControlPlane.BewaartermijnVpsTest do
  @moduledoc """
  Wat er van een verwijderde VPS overblijft, en wanneer.

  De privacyverklaring belooft dat VPS-gegevens dertig dagen na het verwijderen
  weg zijn. Dat stond alleen in de tekst: in de database bleef een verwijderde
  rij staan met het IP-adres, het e-mailadres, de hostsleutel en de versleutelde
  consolesleutel, voor altijd.

  Wat hier vastligt is het onderscheid dat ertoe doet. De rij blijft -- daar
  hangt de administratie aan, en die moet zeven jaar mee. De velden die de
  persoon of zijn machine aanwijzen gaan eruit.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Housekeeping
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  defp vps_met(status, dagen_geleden, extra \\ %{}) do
    user = confirmed_user_fixture()
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()
    toen = Clock.shift(-dagen_geleden * 24 * 3600)

    %Vps{}
    |> Vps.changeset(%{
      name: "web",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: status,
      owner_id: user.id,
      owner_email: user.email
    })
    |> Repo.insert!()
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          ip_address: "10.10.0.#{System.unique_integer([:positive])}",
          ssh_host_key: "ssh-ed25519 AAAAhostkey",
          console_key_public: "ssh-rsa AAAApubliek",
          console_key_sealed: <<1, 2, 3>>,
          updated_at: toen
        },
        extra
      )
    )
    |> Repo.update!()
  end

  test "een VPS die langer dan dertig dagen weg is, laat niets persoonlijks achter" do
    vps = vps_met(:deleted, 40)
    user_id = vps.owner_id

    assert Housekeeping.scrub_deleted_vpses(30) == 1

    opnieuw = Repo.get!(Vps, vps.id)
    assert is_nil(opnieuw.ip_address)
    assert is_nil(opnieuw.owner_email)
    assert is_nil(opnieuw.ssh_host_key)
    assert is_nil(opnieuw.console_key_sealed)
    assert is_nil(opnieuw.console_key_public)

    # De rij zelf blijft, met de link naar de administratie. Zou die verdwijnen,
    # dan is niet meer na te gaan waar een grootboekregel bij hoort -- en dat
    # moet zeven jaar kunnen.
    assert opnieuw.owner_id == user_id
    assert opnieuw.status == :deleted
  end

  test "binnen de termijn blijft alles staan" do
    vps = vps_met(:deleted, 5)

    assert Housekeeping.scrub_deleted_vpses(30) == 0
    assert Repo.get!(Vps, vps.id).ip_address != nil
  end

  test "een draaiende VPS wordt nooit geraakt, hoe oud ook" do
    # De veeg kijkt naar `updated_at`, en een VPS die maanden rustig draait heeft
    # een oude `updated_at`. Zou de status niet meewegen, dan wist deze veeg het
    # IP-adres van een machine waar iemand op dat moment op werkt.
    vps = vps_met(:active, 400)

    assert Housekeeping.scrub_deleted_vpses(30) == 0
    assert Repo.get!(Vps, vps.id).ip_address != nil
  end

  test "twee keer vegen doet de tweede keer niets" do
    _vps = vps_met(:deleted, 40)

    assert Housekeeping.scrub_deleted_vpses(30) == 1
    assert Housekeeping.scrub_deleted_vpses(30) == 0
  end
end
