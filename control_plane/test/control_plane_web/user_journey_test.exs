defmodule ControlPlaneWeb.UserJourneyTest do
  @moduledoc """
  De weg die een klant werkelijk aflegt, in één doorlopende test per reis.

  De losse controllertests dekken elk endpoint apart af. Wat ze niet dekken is
  de overgang: dat het token uit stap één de bestelling in stap vier draagt, dat
  het tegoed dat is opgewaardeerd hetzelfde tegoed is dat wordt afgeschreven, en
  dat een VPS verwijderen ook de maandelijkse afschrijving stopt. Precies daar
  zaten de fouten die eerder op productie zijn opgedoken.

  Alles loopt door de publieke HTTP-API, met de antwoorden van de vorige stap als
  invoer voor de volgende — geen contextmodules die de webkant overslaan.
  """
  use ControlPlaneWeb.ConnCase, async: false

  import ControlPlane.Fixtures, only: [with_second_factor: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Credits
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription

  @password "test-only-password-4f2b9c1e"

  setup do
    region =
      Repo.insert!(%Region{
        code: "nl-#{System.unique_integer([:positive])}",
        name: "Nederland"
      })

    Repo.insert!(%Node{
      name: "node-#{System.unique_integer([:positive])}",
      region_id: region.id,
      hypervisor: :proxmox,
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now(),
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000
    })

    # Unieke naam: packages.name heeft een uniqueness-index, en deze setup draait
    # per test opnieuw.
    pakket =
      Repo.insert!(%Package{
        name: "Starter-#{System.unique_integer([:positive])}",
        cpu_cores: 1,
        ram_gb: 1,
        disk_gb: 20,
        price_monthly: Decimal.new("3.99"),
        is_available: true
      })

    %{region: region, pakket: pakket}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  # Registreren én bevestigen. Het welkomsttegoed komt pas bij het bevestigen —
  # een bot die nooit een e-mail opent krijgt geen krediet — dus een reis die de
  # bevestiging overslaat strandt op een lege portemonnee in plaats van op wat
  # hij wil toetsen.
  defp klant(conn, naam) do
    email = "#{naam}-#{System.unique_integer([:positive])}@bunk.test"

    token =
      conn
      |> post(~p"/api/v1/auth/register", %{"email" => email, "password" => @password})
      |> json_response(201)
      |> Map.fetch!("token")

    gebruiker = Accounts.get_user_by_email(email)
    {:ok, bevestig_token} = Accounts.deliver_user_confirmation_instructions(gebruiker)
    conn |> post(~p"/api/v1/auth/confirm", %{"token" => bevestig_token}) |> json_response(200)

    {email, token}
  end

  defp bestelling(region, extra \\ %{}) do
    Map.merge(
      %{
        "region_id" => region.id,
        "name" => "web-#{System.unique_integer([:positive])}",
        "vcpu" => 1,
        "ram_mb" => 1024,
        "disk_gb" => 20,
        "immediate_delivery_consent" => true
      },
      extra
    )
  end

  describe "de weg van registratie tot draaiende VPS" do
    test "een nieuwe klant komt binnen, bestelt en ziet zijn server terug", %{
      conn: conn,
      region: region
    } do
      # 1. Registreren en het e-mailadres bevestigen.
      {email, token} = klant(conn, "reis")
      assert is_binary(token)

      ik = conn |> bearer(token) |> get(~p"/api/v1/auth/me") |> json_response(200)
      assert ik["user"]["email"] == email
      assert ik["user"]["confirmed_at"]

      # 2. Het welkomsttegoed staat er; zonder dat kan er niets besteld worden.
      saldo =
        conn |> bearer(token) |> get(~p"/api/v1/billing/wallet") |> json_response(200)

      assert saldo["balance_cents"] == Credits.signup_bonus_cents()
      assert saldo["balance_cents"] > 0

      # 3. Bestellen met hetzelfde token uit stap 1.
      besteld =
        conn
        |> bearer(token)
        |> post(~p"/api/v1/vpses", bestelling(region))
        |> json_response(201)

      vps_id = besteld["vps"]["id"]
      assert besteld["vps"]["status"] in ["queued", "provisioning"]

      # 4. De VPS staat in zijn eigen lijst, en het tegoed is met de pakketprijs
      #    gedaald. Dat de lijst hem toont én de afschrijving klopt is samen het
      #    bewijs dat bestelling en grootboek over dezelfde VPS gaan.
      lijst = conn |> bearer(token) |> get(~p"/api/v1/vpses") |> json_response(200)
      assert [%{"id" => ^vps_id}] = lijst["vpses"]

      na = conn |> bearer(token) |> get(~p"/api/v1/billing/wallet") |> json_response(200)
      assert na["balance_cents"] == saldo["balance_cents"] - 399

      # 5. Er loopt nu een abonnement voor deze machine.
      assert %Subscription{status: :active} = Repo.get_by(Subscription, vps_id: vps_id)
    end

    test "opzeggen door te verwijderen stopt ook de maandelijkse afschrijving", %{
      conn: conn,
      region: region
    } do
      {_email, token} = klant(conn, "opzeg")

      vps_id =
        conn
        |> bearer(token)
        |> post(~p"/api/v1/vpses", bestelling(region))
        |> json_response(201)
        |> get_in(["vps", "id"])

      assert %Subscription{status: :active} = Repo.get_by(Subscription, vps_id: vps_id)

      conn |> bearer(token) |> delete(~p"/api/v1/vpses/#{vps_id}") |> json_response(202)

      # Dit is de kern van wat de voorwaarden beloven: verwijderen is opzeggen.
      # Bleef het abonnement actief, dan bleef de klant elke maand betalen voor
      # een machine die niet meer bestaat.
      assert %Subscription{status: :cancelled} = Repo.get_by(Subscription, vps_id: vps_id)
    end

    test "zonder instemming met directe levering geen VPS en geen afschrijving", %{
      conn: conn,
      region: region
    } do
      {_email, token} = klant(conn, "herroep")

      voor = conn |> bearer(token) |> get(~p"/api/v1/billing/wallet") |> json_response(200)

      params = region |> bestelling() |> Map.delete("immediate_delivery_consent")

      assert %{"error" => "no_delivery_consent"} =
               conn |> bearer(token) |> post(~p"/api/v1/vpses", params) |> json_response(422)

      na = conn |> bearer(token) |> get(~p"/api/v1/billing/wallet") |> json_response(200)
      assert na["balance_cents"] == voor["balance_cents"]
      assert Repo.aggregate(Vps, :count, :id) == 0
    end
  end

  describe "wat een klant niet kan" do
    setup %{conn: conn, region: region} do
      {_, eigenaar} = klant(conn, "eigenaar")
      {_, vreemde} = klant(conn, "vreemde")

      vps_id =
        conn
        |> bearer(eigenaar)
        |> post(~p"/api/v1/vpses", bestelling(region))
        |> json_response(201)
        |> get_in(["vps", "id"])

      %{eigenaar: eigenaar, vreemde: vreemde, vps_id: vps_id}
    end

    test "andermans VPS bestaat voor hem niet", %{conn: conn, vreemde: vreemde, vps_id: id} do
      # 404 en niet 403: een 403 bevestigt dat het id bestaat, en dat is al
      # informatie die een vreemde niet hoort te krijgen.
      assert conn |> bearer(vreemde) |> get(~p"/api/v1/vpses/#{id}") |> json_response(404)
      assert conn |> bearer(vreemde) |> delete(~p"/api/v1/vpses/#{id}") |> json_response(404)
      assert conn |> bearer(vreemde) |> post(~p"/api/v1/vpses/#{id}/stop") |> json_response(404)

      assert %{"vpses" => []} =
               conn |> bearer(vreemde) |> get(~p"/api/v1/vpses") |> json_response(200)
    end

    test "het beheer is dicht voor een gewone klant", %{conn: conn, eigenaar: eigenaar} do
      for pad <- ["/api/v1/beheer/stats", "/api/v1/beheer/users", "/api/v1/beheer/omzet"] do
        assert conn |> bearer(eigenaar) |> get(pad) |> json_response(403)
      end
    end

    test "zonder token is alles dicht", %{conn: conn, vps_id: id} do
      assert conn |> get(~p"/api/v1/vpses") |> json_response(401)
      assert conn |> get(~p"/api/v1/vpses/#{id}") |> json_response(401)
      assert conn |> get(~p"/api/v1/billing/wallet") |> json_response(401)
    end

    test "uitloggen maakt het token meteen waardeloos", %{conn: conn, eigenaar: token} do
      assert conn |> bearer(token) |> get(~p"/api/v1/auth/me") |> json_response(200)
      assert conn |> bearer(token) |> delete(~p"/api/v1/auth/logout") |> response(204)
      assert conn |> bearer(token) |> get(~p"/api/v1/auth/me") |> json_response(401)
    end
  end

  describe "de weg van de beheerder" do
    setup %{conn: conn} do
      {:ok, admin} =
        Accounts.register_user(%{
          email: "admin-#{System.unique_integer([:positive])}@bunk.test",
          password: @password
        })

      admin =
        admin |> Ecto.Changeset.change(role: :admin) |> Repo.update!() |> with_second_factor()

      token =
        admin
        |> Accounts.generate_user_session_token(mfa: true)
        |> Base.url_encode64(padding: false)

      %{conn: conn, admin: admin, admin_token: token}
    end

    test "een beheerder ziet de fleet en kan een node toevoegen", %{
      conn: conn,
      admin_token: token
    } do
      nodes = conn |> bearer(token) |> get(~p"/api/v1/beheer/nodes") |> json_response(200)
      assert length(nodes["nodes"]) == 1

      uitgifte =
        conn
        |> bearer(token)
        |> post(~p"/api/v1/beheer/enroll-tokens", %{})
        |> json_response(201)

      # De installatieregel is wat de operator op de machine plakt; staat het
      # token er niet in, dan is het antwoord waardeloos ook al ziet het er goed uit.
      assert String.contains?(uitgifte["install"], uitgifte["enroll_token"])
    end

    test "de omzetpagina telt alleen betaalde opwaarderingen", %{
      conn: conn,
      admin: admin,
      admin_token: token
    } do
      # Welkomsttegoed is weggegeven en handmatig tegoed is geen betaling; alleen
      # een opwaardering die bij de betaalprovider bestond telt als omzet.
      {:ok, _} = Credits.add_entry(admin.id, 5000, "admin_topup", "Handmatig door beheerder")

      {:ok, req} =
        Credits.create_mollie_topup(admin.id, 2500, "tr_#{System.unique_integer([:positive])}")

      {:ok, _} = Credits.mark_topup_paid(req.id, "mollie")

      omzet = conn |> bearer(token) |> get(~p"/api/v1/beheer/omzet") |> json_response(200)

      assert omzet["total"]["payments"] == 1
      assert omzet["total"]["gross_cents"] == 2500
      assert omzet["total"]["net_cents"] + omzet["total"]["vat_cents"] == 2500
      assert [%{"reference" => ref}] = omzet["invoices"]
      assert ref == req.reference
    end
  end
end
