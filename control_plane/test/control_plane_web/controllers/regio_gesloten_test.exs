defmodule ControlPlaneWeb.RegioGeslotenTest do
  @moduledoc """
  Een gesloten locatie neemt ook geen bestelling aan die hem bij naam noemt.

  `enabled: false` is de knop waarmee een locatie wordt afgebouwd: wat draait
  blijft draaien, er komt niets nieuws bij. Alleen deed hij dat laatste niet.
  De regio verdween uit `GET /regions`, en dat was alles -- wie de code zelf
  meestuurde kwam er gewoon langs.

  Het wrange was welke kant beschermd was. `Fleet.auto_region_id/1` slaat een
  uitgeschakelde regio wél over, met een comment erbij waarom. Alleen de BEWUSTE
  keuze van een klant ging er ongehinderd langs -- een oud tabblad, een script,
  iemands eigen client.

  Gemeten op productie op 23 september: ehv stond dicht omdat de webterminal
  daar niet werkte, en een bestelling met `region_code: "ehv"` gaf 201 en een
  provisionende machine. Precies de klant die we probeerden te beschermen.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures
  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Credits
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  setup %{conn: conn} do
    user = confirmed_user_fixture()
    {:ok, _} = Credits.add_entry(user.id, 50_000, "test_bonus", "ruim tegoed")

    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)

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
      available_disk_gb: 1000
    })
    |> Repo.insert!()

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
      region: region
    }
  end

  defp bestelling(extra) do
    Map.merge(
      %{
        "vcpu" => 1,
        "ram_mb" => 1024,
        "disk_gb" => 20,
        "name" => "Testmachine",
        "immediate_delivery_consent" => true
      },
      extra
    )
  end

  defp sluit(region), do: Repo.update!(Ecto.Changeset.change(region, enabled: false))

  defp aantal_vpsen(user),
    do: Repo.aggregate(from(v in Vps, where: v.owner_id == ^user.id), :count)

  test "een open locatie neemt gewoon aan", %{conn: conn, region: region} do
    # De tegenproef. Zonder deze test zou een fix die ALLES weigert er even goed
    # uitzien als een fix die alleen gesloten locaties weigert.
    assert %{"vps" => _} =
             conn
             |> post(~p"/api/v1/vpses", bestelling(%{"region_code" => region.code}))
             |> json_response(201)
  end

  test "een gesloten locatie weigert een bestelling op code", %{
    conn: conn,
    user: user,
    region: region
  } do
    sluit(region)

    assert %{"error" => "region_closed"} =
             conn
             |> post(~p"/api/v1/vpses", bestelling(%{"region_code" => region.code}))
             |> json_response(409)

    assert aantal_vpsen(user) == 0
  end

  test "en ook een bestelling op id", %{conn: conn, user: user, region: region} do
    # Twee wegen naar dezelfde locatie. Eén dichtzetten en de andere vergeten is
    # hoe dit gat ontstond.
    sluit(region)

    assert %{"error" => "region_closed"} =
             conn
             |> post(~p"/api/v1/vpses", bestelling(%{"region_id" => region.id}))
             |> json_response(409)

    assert aantal_vpsen(user) == 0
  end

  test "een locatie die niet bestaat blijft not_found en geen closed", %{
    conn: conn,
    region: region
  } do
    # Het verschil hoort te blijven bestaan: "bestaat niet" laat iemand zijn
    # tikfout zoeken, "gesloten" laat hem een andere locatie kiezen. Ze door
    # elkaar halen stuurt de klant de verkeerde kant op.
    sluit(region)

    assert %{"error" => "region_not_found"} =
             conn
             |> post(~p"/api/v1/vpses", bestelling(%{"region_code" => "bestaat-echt-niet"}))
             |> json_response(422)
  end
end
