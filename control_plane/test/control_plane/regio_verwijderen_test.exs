defmodule ControlPlane.RegioVerwijderenTest do
  @moduledoc """
  Een locatie die nooit gebruikt is mag weg; een locatie met geschiedenis niet.

  Het verschil zit niet in netheid maar in wat er kapot zou gaan. Nodes, VPS'en
  en uitnodigingen verwijzen naar een regio, en die verwijzingen staan in de
  database op `restrict`. Ook een allang verwijderde VPS houdt de zijne vast,
  want die rij blijft staan voor de administratie -- zou de locatie weg kunnen,
  dan wees de geschiedenis naar iets wat niemand meer kan opzoeken.

  Wat er per geval terugkomt is een eigen reden, want ze vragen om iets anders:
  nodes kun je verplaatsen, een uitnodiging kun je intrekken, en aan een
  VPS-geschiedenis valt niets te doen.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures
  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.EnrollToken
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Regions
  alias ControlPlane.Fleet.Vps

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Regio #{code}"}) |> Repo.insert!()
  end

  test "een ongebruikte locatie gaat weg" do
    r = regio()

    assert Regions.delete_region(r.id) == :ok
    refute Repo.get(Region, r.id)
  end

  test "met een node erin niet, en dat zegt hij ook" do
    r = regio()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: r.id})
    |> Repo.insert!()

    assert Regions.delete_region(r.id) == {:error, :has_nodes}
    assert Repo.get(Region, r.id)
  end

  test "een verwijderde VPS houdt de locatie niet tegen, maar laat hem wel los" do
    # De VPS is weg voor de klant; zijn rij staat er nog voor de administratie.
    # Die rij mag de locatie niet gijzelen -- anders is elke locatie die ooit is
    # gebruikt onverwijderbaar. Wat hij kwijtraakt is het label van de locatie;
    # het grootboek en het abonnement verwijzen naar de VPS en niet naar de regio.
    r = regio()
    user = confirmed_user_fixture()

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "oud",
        region_id: r.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 10,
        status: :deleted,
        owner_id: user.id,
        owner_email: user.email
      })
      |> Repo.insert!()

    assert Regions.delete_region(r.id) == :ok
    refute Repo.get(Region, r.id)

    opnieuw = Repo.get!(Vps, vps.id)
    assert is_nil(opnieuw.region_id)
    assert opnieuw.status == :deleted
  end

  test "een VPS die nog draait houdt de locatie wel tegen" do
    # Hier zou verwijderen betekenen dat een machine die iemand gebruikt niet
    # meer bij een locatie hoort.
    r = regio()
    user = confirmed_user_fixture()

    %Vps{}
    |> Vps.changeset(%{
      name: "draait",
      region_id: r.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :active,
      owner_id: user.id,
      owner_email: user.email
    })
    |> Repo.insert!()

    assert Regions.delete_region(r.id) == {:error, :has_vpses}
    assert Repo.get(Region, r.id)
  end

  test "een gebruikte of verlopen uitnodiging houdt niets tegen" do
    # Dit stond in de weg zonder dat er iets te zien was: een uitnodiging die al
    # is ingewisseld of allang is verlopen blijft als rij staan, en die telde mee
    # als "er staat nog een uitnodiging open". Een melding die niet klopt met wat
    # iemand op het scherm ziet, is erger dan geen melding.
    r = regio()

    %EnrollToken{}
    |> EnrollToken.changeset(%{
      token_hash: "gebruikt-#{System.unique_integer([:positive])}",
      region_id: r.id,
      expires_at: Clock.shift(3600),
      used_at: Clock.now()
    })
    |> Repo.insert!()

    %EnrollToken{}
    |> EnrollToken.changeset(%{
      token_hash: "verlopen-#{System.unique_integer([:positive])}",
      region_id: r.id,
      expires_at: Clock.shift(-3600)
    })
    |> Repo.insert!()

    assert Regions.delete_region(r.id) == :ok
    refute Repo.get(Region, r.id)
    # En ze zijn meegegaan: een token wijst naar een locatie die niet meer bestaat.
    assert Repo.aggregate(from(t in EnrollToken, where: t.region_id == ^r.id), :count) == 0
  end

  test "een uitnodiging die iemand nog kan gebruiken houdt de locatie wel tegen" do
    r = regio()

    %EnrollToken{}
    |> EnrollToken.changeset(%{
      token_hash: "open-#{System.unique_integer([:positive])}",
      region_id: r.id,
      expires_at: Clock.shift(3600)
    })
    |> Repo.insert!()

    assert Regions.delete_region(r.id) == {:error, :has_enroll_tokens}
    assert Repo.get(Region, r.id)
  end

  test "een locatie die niet bestaat" do
    assert Regions.delete_region(Ecto.UUID.generate()) == {:error, :not_found}
  end
end
