defmodule ControlPlaneWeb.UserSessionMfaTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Accounts

  @pw "test-only-password-4f2b9c1e"

  defp mfa_user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: @pw})
    u = Accounts.start_totp_setup(u)
    {:ok, u} = Accounts.confirm_totp(u, NimbleTOTP.verification_code(u.totp_secret))
    u
  end

  test "login without MFA goes straight to /app", %{conn: conn} do
    {:ok, _} = Accounts.register_user(%{email: "plain@bunk.test", password: @pw})
    conn = post(conn, ~p"/login", %{user: %{email: "plain@bunk.test", password: @pw}})
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
  end

  test "login with MFA active requires the second factor", %{conn: conn} do
    u = mfa_user("mfa@bunk.test")

    conn = post(conn, ~p"/login", %{user: %{email: "mfa@bunk.test", password: @pw}})
    assert redirected_to(conn) == ~p"/login/mfa"
    refute get_session(conn, :user_token)
    assert get_session(conn, :mfa_pending_user_id) == u.id

    bad = post(conn, ~p"/login/mfa", %{totp: %{code: "000000"}})
    assert html_response(bad, 401) =~ "Ongeldige code"
    refute get_session(bad, :user_token)

    good =
      post(conn, ~p"/login/mfa", %{totp: %{code: NimbleTOTP.verification_code(u.totp_secret)}})

    assert redirected_to(good) == ~p"/"
    assert get_session(good, :user_token)
  end

  test "wrong password never reaches the MFA step", %{conn: conn} do
    mfa_user("mfa2@bunk.test")

    conn =
      post(conn, ~p"/login", %{user: %{email: "mfa2@bunk.test", password: "wrong-password-xx"}})

    assert html_response(conn, 401) =~ "Ongeldig"
    refute get_session(conn, :mfa_pending_user_id)
  end

  test "the challenge page redirects to /login without a pending login", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/login/mfa")) == ~p"/login"
  end

  test "een sessie na een login met code onthoudt dat de tweede factor gezien is", %{conn: conn} do
    u = mfa_user("mfa-sessie@bunk.test")
    conn = post(conn, ~p"/login", %{user: %{email: "mfa-sessie@bunk.test", password: @pw}})

    good =
      post(conn, ~p"/login/mfa", %{totp: %{code: NimbleTOTP.verification_code(u.totp_secret)}})

    assert Accounts.session_mfa?(get_session(good, :user_token))
  end

  test "een account met alleen een passkey komt hier niet binnen met een wachtwoord", %{
    conn: conn
  } do
    # Dit scherm kent geen passkeys; eerst liet het zo'n account door op
    # wachtwoord alleen.
    {:ok, u} = Accounts.register_user(%{email: "passkey@bunk.test", password: @pw})

    ControlPlane.Repo.insert!(%ControlPlane.Accounts.Passkey{
      user_id: u.id,
      credential_id: "cred-#{System.unique_integer([:positive])}",
      public_key: <<1, 2, 3>>,
      sign_count: 0,
      label: "Sleutel"
    })

    conn = post(conn, ~p"/login", %{user: %{email: "passkey@bunk.test", password: @pw}})
    assert html_response(conn, 401) =~ "passkey"
    refute get_session(conn, :user_token)
  end

  test "foute codes tellen per account, ook op dit scherm", %{conn: conn} do
    u = mfa_user("mfa-teller@bunk.test")
    conn = post(conn, ~p"/login", %{user: %{email: "mfa-teller@bunk.test", password: @pw}})

    for _ <- 1..5, do: post(conn, ~p"/login/mfa", %{totp: %{code: "000000"}})

    goed =
      post(conn, ~p"/login/mfa", %{totp: %{code: NimbleTOTP.verification_code(u.totp_secret)}})

    assert html_response(goed, 401) =~ "Ongeldige code"
  end
end
