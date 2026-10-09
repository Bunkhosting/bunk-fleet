defmodule ControlPlaneWeb.BeheerMfaTest do
  @moduledoc """
  Het beheerpaneel eist een tweede factor.

  Achter die pijplijn staat elk account, elke VPS van elke klant en de knop die
  tegoed bijboekt. Eén gestolen wachtwoord of één meegelezen sessie mag dat niet
  waard zijn. Een beheerder zonder tweede factor komt er niet in -- ook niet
  "even alleen kijken", want de lijst met klanten is zelf al het probleem.
  """
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.Passkey
  alias ControlPlane.Repo

  defp gebruiker(rol) do
    email = "#{rol}-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u |> Ecto.Changeset.change(%{role: rol}) |> Repo.update!()
  end

  # Een sessie zoals de login hem uitgeeft: met tweede factor als het account er
  # een heeft. Zie de tests onderaan voor een sessie die er nooit een liet zien.
  defp ingelogd(conn, user) do
    token =
      user
      |> Accounts.generate_user_session_token(mfa: Accounts.has_second_factor?(user))
      |> Base.url_encode64(padding: false)

    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp zonder_tweede_factor_ingelogd(conn, user) do
    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp met_totp(user) do
    user
    |> Ecto.Changeset.change(%{
      totp_secret: "ABCDEFGHIJKLMNOP",
      totp_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update!()
  end

  defp met_passkey(user) do
    Repo.insert!(%Passkey{
      user_id: user.id,
      credential_id: "cred-#{System.unique_integer([:positive])}",
      public_key: <<1, 2, 3>>,
      sign_count: 0,
      label: "Testsleutel"
    })

    user
  end

  test "een beheerder zonder tweede factor komt er niet in", %{conn: conn} do
    resp =
      conn |> ingelogd(gebruiker(:admin)) |> get(~p"/api/v1/beheer/stats") |> json_response(403)

    assert resp["error"] == "admin_mfa_required"
    assert resp["detail"] =~ "Beveiliging"
  end

  test "met een authenticator-app wel", %{conn: conn} do
    beheerder = gebruiker(:admin) |> met_totp()

    assert conn |> ingelogd(beheerder) |> get(~p"/api/v1/beheer/stats") |> json_response(200)
  end

  test "een passkey telt net zo goed", %{conn: conn} do
    # Een passkey is aan het domein gebonden en daarmee bestand tegen phishing;
    # daarnaast ook nog TOTP eisen zou strenger lijken en niets toevoegen.
    beheerder = gebruiker(:admin) |> met_passkey()

    assert conn |> ingelogd(beheerder) |> get(~p"/api/v1/beheer/stats") |> json_response(200)
  end

  test "een gewone gebruiker hoort niets over een tweede factor", %{conn: conn} do
    # Hij krijgt `forbidden` en niet `mfa_required`: dat laatste zou verklappen
    # dat hij op een beheerdersdrempel stuitte die hij bijna haalde.
    resp =
      conn |> ingelogd(gebruiker(:user)) |> get(~p"/api/v1/beheer/stats") |> json_response(403)

    assert resp["error"] == "forbidden"
  end

  test "de eis geldt ook voor de handelingen, niet alleen de lijsten", %{conn: conn} do
    beheerder = gebruiker(:admin)
    slachtoffer = gebruiker(:user)

    conn
    |> ingelogd(beheerder)
    |> post(~p"/api/v1/beheer/users/#{slachtoffer.id}/credit", %{"amount_cents" => 10_000})
    |> json_response(403)
  end

  describe "een sessie die alleen met een wachtwoord begon" do
    # De aanval: het wachtwoord van een beheerder zonder 2FA, inloggen, in die
    # sessie zelf een authenticator aanzetten, en het paneel staat open. Het
    # ACCOUNT heeft dan een tweede factor; de SESSIE heeft hem nooit laten zien.
    test "komt niet in het paneel, ook als het account inmiddels 2FA heeft", %{conn: conn} do
      beheerder = gebruiker(:admin) |> met_totp()

      resp =
        conn
        |> zonder_tweede_factor_ingelogd(beheerder)
        |> get(~p"/api/v1/beheer/stats")
        |> json_response(403)

      assert resp["error"] == "admin_reauth_required"
    end

    test "/auth/me zegt het, zodat het dashboard het kan uitleggen", %{conn: conn} do
      beheerder = gebruiker(:admin) |> met_totp()

      refute conn
             |> zonder_tweede_factor_ingelogd(beheerder)
             |> get(~p"/api/v1/auth/me")
             |> json_response(200)
             |> get_in(["user", "session_mfa"])

      assert build_conn()
             |> ingelogd(beheerder)
             |> get(~p"/api/v1/auth/me")
             |> json_response(200)
             |> get_in(["user", "session_mfa"])
    end

    test "een echte login met de code geeft een sessie die wel binnenkomt" do
      # Door de echte login heen, niet via de fixture: dat is de weg waarlangs
      # een beheerder zijn sessie krijgt.
      geheim = NimbleTOTP.secret()

      beheerder =
        gebruiker(:admin)
        |> Ecto.Changeset.change(%{
          totp_secret: geheim,
          totp_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update!()

      %{"token" => token} =
        build_conn()
        |> post(~p"/api/v1/auth/login", %{
          "email" => beheerder.email,
          "password" => "Str0ngPassphrase!42",
          "code" => NimbleTOTP.verification_code(geheim)
        })
        |> json_response(200)

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> token)
             |> get(~p"/api/v1/beheer/stats")
             |> json_response(200)
    end
  end
end
