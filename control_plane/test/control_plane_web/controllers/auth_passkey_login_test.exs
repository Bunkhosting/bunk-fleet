defmodule ControlPlaneWeb.AuthPasskeyLoginTest do
  @moduledoc """
  Inloggen met een passkey als tweede factor, gezien vanaf de API.

  Het wachtwoord alleen mag nooit een sessie opleveren zodra er een passkey
  staat — dat is de hele reden om er een te hebben.
  """
  use ControlPlaneWeb.ConnCase, async: false

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.Passkey
  alias ControlPlane.Accounts.PasskeyChallenges
  alias ControlPlane.Accounts.Passkeys
  alias ControlPlane.Accounts.Totp
  alias ControlPlane.Repo

  @password "test-only-password-4f2b9c1e"

  setup do
    PasskeyChallenges.reset()
    :ok
  end

  defp confirmed_user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: @password})
    u |> Ecto.Changeset.change(confirmed_at: ControlPlane.Clock.now()) |> Repo.update!()
  end

  defp with_passkey(u) do
    Repo.insert!(%Passkey{
      user_id: u.id,
      credential_id: :crypto.strong_rand_bytes(32),
      public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7}),
      label: "Telefoon"
    })

    u
  end

  defp login(conn, email, extra \\ %{}) do
    post(
      vanaf_dashboard(conn),
      ~p"/api/v1/auth/login",
      Map.merge(%{"email" => email, "password" => @password}, extra)
    )
  end

  test "wachtwoord alleen geeft geen sessie als er een passkey staat", %{conn: conn} do
    confirmed_user("pl1@bunk.test") |> with_passkey()

    body = conn |> login("pl1@bunk.test") |> json_response(200)

    assert body["mfa_required"] == true
    assert body["methods"] == ["passkey"]
    assert body["totp_required"] == false
    assert is_binary(body["passkey_challenge"]["challenge_id"])
    assert [_] = body["passkey_challenge"]["public_key"]["allowCredentials"]

    # Het enige dat telt: geen token.
    refute Map.has_key?(body, "token")
    refute Map.has_key?(body, "user")
  end

  test "rommel als assertie is 401 en geeft een nieuwe challenge", %{conn: conn} do
    confirmed_user("pl2@bunk.test") |> with_passkey()
    first = conn |> login("pl2@bunk.test") |> json_response(200)
    cid = first["passkey_challenge"]["challenge_id"]

    body =
      conn
      |> login("pl2@bunk.test", %{
        "passkey" => %{
          "challenge_id" => cid,
          "id" => Base.url_encode64("nep", padding: false),
          "response" => %{
            "authenticatorData" => "AA",
            "signature" => "AA",
            "clientDataJSON" => "e30"
          }
        }
      })
      |> json_response(401)

    assert body["error"] == "invalid_passkey"
    refute Map.has_key?(body, "token")
    # De oude challenge is verbruikt; zonder nieuwe kan de klant niet verder.
    assert is_binary(body["passkey_challenge"]["challenge_id"])
    assert body["passkey_challenge"]["challenge_id"] != cid
  end

  test "een account met alleen TOTP verandert niet van gedrag", %{conn: conn} do
    u = confirmed_user("pl3@bunk.test")
    u = Totp.start_totp_setup(u)
    code = NimbleTOTP.verification_code(u.totp_secret)
    {:ok, _} = Totp.confirm_totp(u, code)

    body = conn |> login("pl3@bunk.test") |> json_response(200)
    assert body["totp_required"] == true
    assert body["methods"] == ["totp"]
    assert body["passkey_challenge"] == nil
  end

  test "zonder tweede factor logt een wachtwoord gewoon in", %{conn: conn} do
    confirmed_user("pl4@bunk.test")
    out = conn |> login("pl4@bunk.test")
    body = json_response(out, 200)
    # De sessie zit in de HttpOnly-cookie, niet in de body.
    assert is_binary(out.resp_cookies["bunk_session"].value)
    refute Map.has_key?(body, "token")
    assert body["user"]["passkeys_enabled"] == false
  end

  test "de beheer-endpoints weigeren rommel en andermans sleutels", %{conn: conn} do
    a = confirmed_user("pl5a@bunk.test")
    b = confirmed_user("pl5b@bunk.test") |> with_passkey()
    [pk_b] = Passkeys.list_passkeys(b)

    token = a |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    authed = put_req_header(conn, "authorization", "Bearer " <> token)

    assert %{"passkeys" => []} = authed |> get(~p"/api/v1/auth/passkeys") |> json_response(200)

    %{"challenge_id" => cid} =
      authed |> post(~p"/api/v1/auth/passkeys/challenge") |> json_response(200)

    assert %{"error" => "invalid_passkey"} =
             authed
             |> post(~p"/api/v1/auth/passkeys", %{
               "challenge_id" => cid,
               "label" => "x",
               "credential" => %{
                 "response" => %{"attestationObject" => "AA", "clientDataJSON" => "e30"}
               }
             })
             |> json_response(422)

    # Met het juiste wachtwoord van a: anders strandt het al daarop en zegt dit
    # niets over andermans sleutel.
    assert %{"error" => "not_found"} =
             authed
             |> delete(~p"/api/v1/auth/passkeys/#{pk_b.id}", %{"current_password" => @password})
             |> json_response(404)

    assert Passkeys.passkeys_active?(b)
  end
end
