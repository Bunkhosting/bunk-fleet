defmodule ControlPlaneWeb.BestellingDubbelTest do
  @moduledoc """
  De twee uitkomsten van `ControlPlane.Idempotency` die nog geen test hadden.

  `vps_idempotentie_test.exs` dekt de gelukkige gevallen: twee keer dezelfde
  sleutel levert één VPS en één afschrijving op, en verschillende sleutels zijn
  verschillende bestellingen. Wat daar niet in zit zijn de twee randen waar het
  geld echt fout kan gaan:

    * **`:in_flight`** -- een tweede verzoek terwijl het eerste nog loopt. Dat
      mag niet alsnog een VPS aanmaken (dan staan er twee) en ook niet een
      antwoord verzinnen (dan denkt de klant dat hij er een heeft die er niet
      is). Het hoort te wachten, en dat is een 409.
    * **vrijgeven na een mislukking** -- een bestelling die strandt moet de
      sleutel teruggeven. Blijft hij plakken, dan sluit hij de klant buiten van
      zijn eigen bestelling: elke herhaling met dezelfde sleutel loopt dan
      eeuwig op 409, en de enige uitweg is een nieuwe sleutel die de browser
      niet uit zichzelf verzint.
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
  alias ControlPlane.Idempotency
  alias ControlPlane.Idempotency.Key
  alias ControlPlane.Repo

  setup %{conn: conn} do
    user = confirmed_user_fixture()
    {:ok, _} = Credits.add_entry(user.id, 50_000, "admin_adjustment", "ruim tegoed")

    token =
      user
      |> Accounts.generate_user_session_token()
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

  defp bestelling(region) do
    %{
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

  test "een bestelling die nog loopt geeft 409 en maakt geen tweede VPS", %{
    conn: conn,
    user: user,
    region: region
  } do
    # De rij staat er al en is nog niet afgerond -- precies de toestand waarin
    # het eerste verzoek zich bevindt als de klant ongeduldig opnieuw klikt.
    # Hij wordt hier met de hand gezet omdat twee gelijktijdige HTTP-verzoeken
    # in één sandbox-verbinding niet na te bootsen zijn; het is dezelfde rij die
    # `Idempotency.claim/3` zou hebben achtergelaten.
    sleutel = Ecto.UUID.generate()

    %Key{}
    |> Key.changeset(%{
      user_id: user.id,
      key: sleutel,
      scope: Idempotency.vps_create(),
      status: "in_flight"
    })
    |> Repo.insert!()

    saldo_vooraf = Credits.balance_cents(user.id)

    assert %{"error" => "order_in_progress"} =
             conn
             |> put_req_header("idempotency-key", sleutel)
             |> post(~p"/api/v1/vpses", bestelling(region))
             |> json_response(409)

    assert aantal_vpsen(user) == 0
    # En vooral: een 409 mag niet onderweg al afgeschreven hebben.
    assert Credits.balance_cents(user.id) == saldo_vooraf
  end

  test "een mislukte bestelling geeft de sleutel vrij", %{
    conn: conn,
    user: user,
    region: region
  } do
    # De klant klikt, de bestelling wordt geweigerd (hier: zonder bevestiging van
    # onmiddellijke levering, want die weigering komt ná de claim), hij vinkt het
    # vakje aan en klikt opnieuw. De browser stuurt dezelfde sleutel mee. Zou de
    # sleutel blijven plakken, dan kreeg hij nu 409 en kwam hij er nooit meer uit.
    sleutel = Ecto.UUID.generate()
    volledig = bestelling(region)
    zonder = Map.delete(volledig, "immediate_delivery_consent")

    assert conn
           |> put_req_header("idempotency-key", sleutel)
           |> post(~p"/api/v1/vpses", zonder)
           |> json_response(422)

    assert Repo.aggregate(from(k in Key, where: k.user_id == ^user.id), :count) == 0

    assert conn
           |> put_req_header("idempotency-key", sleutel)
           |> post(~p"/api/v1/vpses", bestelling(region))
           |> json_response(201)

    assert aantal_vpsen(user) == 1
  end

  test "een sleutel die niet past wordt geweigerd, niet afgekapt", %{
    conn: conn,
    user: user,
    region: region
  } do
    # Deze test verving er een die aantoonde dat afkappen stukging: de sleutel
    # werd afgekapt bij het opslaan en volledig gebruikt bij het opzoeken, dus de
    # opzoeker vond niets en de code viel terug op "geen sleutel" -- tweede VPS,
    # tweede afschrijving.
    #
    # Afkappen aan beide kanten repareert dat en introduceert iets ergers: twee
    # verschillende lange sleutels worden na afkappen identiek, en dan krijgt een
    # klant bij zijn tweede, écht andere bestelling de VPS van de eerste terug.
    # Een sleutel die niet in de kolom past is een fout van de client, en die
    # hoort hij te horen.
    saldo_vooraf = Credits.balance_cents(user.id)

    resp =
      conn
      |> put_req_header("idempotency-key", String.duplicate("a", 250))
      |> post(~p"/api/v1/vpses", bestelling(region))
      |> json_response(422)

    assert resp["error"] == "invalid_idempotency_key"
    assert aantal_vpsen(user) == 0
    assert Credits.balance_cents(user.id) == saldo_vooraf
  end
end
