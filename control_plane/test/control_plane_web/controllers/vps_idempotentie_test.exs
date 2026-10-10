defmodule ControlPlaneWeb.VpsIdempotentieTest do
  @moduledoc """
  Een bestelling die twee keer binnenkomt levert één VPS op.

  Het geval: een klant klikt op bestellen, de verbinding valt weg vlak voordat
  het antwoord terugkomt, en hij probeert het opnieuw. Zonder sleutel ziet het
  control plane twee volwaardige verzoeken en maakt het twee machines met twee
  afschrijvingen -- die de klant pas op zijn rekening ontdekt.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures
  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Credits
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  setup %{conn: conn} do
    user = confirmed_user_fixture()
    {:ok, _} = Credits.add_entry(user.id, 50_000, "admin_adjustment", "ruim tegoed")

    token =
      user
      |> ControlPlane.Accounts.generate_user_session_token()
      |> Base.url_encode64(padding: false)

    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
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

    # Specificatie moet exact overeenkomen met wat de bestelling vraagt: het
    # control plane zoekt het pakket op cores/ram/disk en weigert zonder match.
    pakket =
      Repo.insert!(%Package{
        name: "Test",
        cpu_cores: 1,
        ram_gb: 1,
        disk_gb: 20,
        price_monthly: Decimal.new("5.00"),
        is_available: true
      })

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      user: user,
      region: region,
      pakket: pakket
    }
  end

  defp bestelling(region) do
    %{
      "package_id" => nil,
      "vcpu" => 1,
      "ram_mb" => 1024,
      "disk_gb" => 20,
      "region_code" => region.code,
      "name" => "Testmachine",
      "immediate_delivery_consent" => true
    }
  end

  defp aantal_vpsen(user),
    do: Repo.aggregate(from(v in Vps, where: v.owner_id == ^user.id), :count)

  test "twee keer dezelfde sleutel levert één VPS op", %{conn: conn, user: user, region: region} do
    body = bestelling(region)
    sleutel = Ecto.UUID.generate()

    eerste =
      conn
      |> put_req_header("idempotency-key", sleutel)
      |> post(~p"/api/v1/vpses", body)
      |> json_response(201)

    tweede =
      conn
      |> put_req_header("idempotency-key", sleutel)
      |> post(~p"/api/v1/vpses", body)
      |> json_response(200)

    assert eerste["vps"]["id"] == tweede["vps"]["id"]
    assert aantal_vpsen(user) == 1
  end

  test "de klant wordt maar één keer afgeschreven", %{conn: conn, user: user, region: region} do
    body = bestelling(region)
    sleutel = Ecto.UUID.generate()

    saldo_vooraf = Credits.balance_cents(user.id)

    conn |> put_req_header("idempotency-key", sleutel) |> post(~p"/api/v1/vpses", body)
    na_eerste = Credits.balance_cents(user.id)

    conn |> put_req_header("idempotency-key", sleutel) |> post(~p"/api/v1/vpses", body)
    na_tweede = Credits.balance_cents(user.id)

    assert na_eerste < saldo_vooraf, "er is niets afgeschreven bij de eerste bestelling"
    assert na_tweede == na_eerste, "de tweede bestelling heeft opnieuw afgeschreven"
  end

  test "twee verschillende sleutels zijn twee bestellingen", %{
    conn: conn,
    user: user,
    region: region
  } do
    # De sleutel mag geen rem op gewone bestellingen zetten.
    body = bestelling(region)

    conn
    |> put_req_header("idempotency-key", Ecto.UUID.generate())
    |> post(~p"/api/v1/vpses", body)

    conn
    |> put_req_header("idempotency-key", Ecto.UUID.generate())
    |> post(~p"/api/v1/vpses", body)

    assert aantal_vpsen(user) == 2
  end

  test "zonder sleutel verandert er niets aan het gedrag", %{
    conn: conn,
    user: user,
    region: region
  } do
    # Een oudere client of een curl-aanroep hoort niet te breken omdat wij iets
    # hebben toegevoegd -- en hoort ook niet ineens beschermd te zijn.
    body = bestelling(region)

    conn |> post(~p"/api/v1/vpses", body) |> json_response(201)
    conn |> post(~p"/api/v1/vpses", body) |> json_response(201)

    assert aantal_vpsen(user) == 2
  end

  test "de sleutel van de ene klant blokkeert de andere niet", %{conn: conn, region: region} do
    # De sleutel is per gebruiker uniek, niet globaal. Anders kan een klant met
    # een geraden sleutel de bestelling van een ander tegenhouden.
    ander = confirmed_user_fixture()
    {:ok, _} = Credits.add_entry(ander.id, 50_000, "admin_adjustment", "ruim tegoed")

    token =
      ander
      |> ControlPlane.Accounts.generate_user_session_token()
      |> Base.url_encode64(padding: false)

    sleutel = "dezelfde-sleutel"
    body = bestelling(region)

    conn |> put_req_header("idempotency-key", sleutel) |> post(~p"/api/v1/vpses", body)

    assert build_conn()
           |> put_req_header("authorization", "Bearer " <> token)
           |> put_req_header("idempotency-key", sleutel)
           |> post(~p"/api/v1/vpses", body)
           |> json_response(201)
  end
end
