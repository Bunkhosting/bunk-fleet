defmodule ControlPlaneWeb.Admin.PanelInsightTest do
  @moduledoc """
  De drie overzichten die een beheerder nodig heeft om een vraag te kunnen
  beantwoorden zonder in de database te kijken: alles over één klant,
  wat er loopt aan abonnementen, en wat de fleet feitelijk heeft gedaan.

  De toegangsgrens zelf staat in panel_authz_test; hier gaat het om de inhoud.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures, only: [with_second_factor: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Credits
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription

  @password "test-only-password-4f2b9c1e"

  defp gebruiker(rol \\ :user) do
    {:ok, u} =
      Accounts.register_user(%{
        email: "pi-#{System.unique_integer([:positive])}@bunk.test",
        password: @password
      })

    if rol == :admin,
      do: u |> Ecto.Changeset.change(role: :admin) |> Repo.update!() |> with_second_factor(),
      else: u
  end

  defp als(conn, u) do
    token =
      u |> Accounts.generate_user_session_token(mfa: true) |> Base.url_encode64(padding: false)

    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp regio,
    do: Repo.insert!(%Region{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})

  defp fleet_node(r),
    do:
      Repo.insert!(%Node{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: r.id,
        hypervisor: :proxmox,
        status: :online
      })

  defp vps(u, r, naam) do
    Repo.insert!(%Vps{
      name: naam,
      owner_id: u.id,
      owner_email: u.email,
      region_id: r.id,
      status: :active,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20
    })
  end

  describe "klantdetail" do
    test "toont saldo, VPS'en, abonnement, opwaarderingen en grootboek", %{conn: conn} do
      admin = gebruiker(:admin)
      klant = gebruiker()
      r = regio()
      machine = vps(klant, r, "web-1")

      {:ok, _} = Credits.add_entry(klant.id, 5000, "admin_topup", "Handmatig")

      {:ok, betaling} =
        Credits.create_mollie_topup(klant.id, 2500, "tr_pi_#{System.unique_integer([:positive])}")

      {:ok, _} = Credits.mark_topup_paid(betaling.id, "mollie")

      Repo.insert!(%Subscription{
        owner_id: klant.id,
        vps_id: machine.id,
        price_monthly: Decimal.new("3.99"),
        status: :active,
        next_billing_date: Date.utc_today()
      })

      body = conn |> als(admin) |> get(~p"/api/v1/beheer/users/#{klant.id}") |> json_response(200)

      assert body["user"]["email"] == klant.email
      assert body["balance_cents"] == 7500
      assert [%{"name" => "web-1"}] = body["vpses"]
      assert [%{"status" => "active", "price_monthly" => "3.99"}] = body["subscriptions"]

      # De opwaarderingen laten zien wat wél en niet een betaling was; dat
      # verschil bepaalt of het bedrag in de btw-aangifte meetelt.
      assert [%{"via_provider" => true, "status" => "paid"}] = body["topups"]
      soorten = Enum.map(body["ledger"], & &1["kind"])
      assert "admin_topup" in soorten
      assert "topup" in soorten
    end

    test "een onbekende of ongeldige id is niet gevonden", %{conn: conn} do
      admin = gebruiker(:admin)

      assert %{"error" => "not_found"} =
               conn
               |> als(admin)
               |> get(~p"/api/v1/beheer/users/00000000-0000-0000-0000-000000000001")
               |> json_response(404)

      # Geen 500 op rommel: de id komt uit de URL en dus van buiten.
      assert conn |> als(admin) |> get("/api/v1/beheer/users/geen-uuid") |> json_response(404)
    end
  end

  describe "abonnementen" do
    test "telt actief en achterstallig, en laat opgezegde weg", %{conn: conn} do
      admin = gebruiker(:admin)
      klant = gebruiker()
      r = regio()

      for {naam, status} <- [{"a", :active}, {"b", :past_due}, {"c", :cancelled}] do
        Repo.insert!(%Subscription{
          owner_id: klant.id,
          vps_id: vps(klant, r, naam).id,
          price_monthly: Decimal.new("10.00"),
          status: status,
          next_billing_date: Date.utc_today()
        })
      end

      body = conn |> als(admin) |> get(~p"/api/v1/beheer/subscriptions") |> json_response(200)

      assert body["active"] == 1
      assert body["past_due"] == 1
      # Een opgezegd abonnement is geen lopende verplichting en telt dus niet mee
      # in het maandbedrag; stond het er wel in, dan leek de omzet hoger dan hij is.
      assert length(body["subscriptions"]) == 2
      assert Decimal.equal?(Decimal.new(body["monthly_total"]), Decimal.new("10.00"))
    end
  end

  describe "activiteit" do
    setup %{conn: conn} do
      admin = gebruiker(:admin)
      klant = gebruiker()
      r = regio()
      n = fleet_node(r)
      machine = vps(klant, r, "web-2")

      Repo.insert!(%Command{
        node_id: n.id,
        vps_id: machine.id,
        kind: :provision,
        status: :failed,
        result: %{"error" => "template ontbreekt", "payload" => %{"cloud_init" => "geheim"}}
      })

      Repo.insert!(%Command{node_id: n.id, kind: :update, status: :done})

      %{conn: conn, admin: admin, node: n}
    end

    test "laat de foutmelding zien, niet alleen het aantal", %{conn: conn, admin: admin} do
      body = conn |> als(admin) |> get(~p"/api/v1/beheer/commands") |> json_response(200)

      mislukt = Enum.find(body["commands"], &(&1["status"] == "failed"))
      assert mislukt["error"] == "template ontbreekt"
      assert mislukt["kind"] == "provision"
      assert mislukt["vps_name"] == "web-2"

      # De payload blijft eruit: daar staat cloud-init in, en dat is invoer van
      # de klant die hier niets toevoegt.
      refute Map.has_key?(mislukt, "payload")
      refute body |> Jason.encode!() |> String.contains?("geheim")
    end

    test "filteren op status", %{conn: conn, admin: admin} do
      body =
        conn
        |> als(admin)
        |> get(~p"/api/v1/beheer/commands?status=failed")
        |> json_response(200)

      assert [%{"status" => "failed"}] = body["commands"]
    end

    test "een onzinnige status of limiet valt terug op alles", %{conn: conn, admin: admin} do
      # Query-parameters komen van buiten; een onbekende waarde mag geen
      # 500 opleveren en geen lege lijst die op "niets gebeurd" lijkt.
      body =
        conn
        |> als(admin)
        |> get(~p"/api/v1/beheer/commands?status=rommel&limit=nee")
        |> json_response(200)

      assert length(body["commands"]) == 2
    end
  end
end
