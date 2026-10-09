defmodule ControlPlaneWeb.AuthControllerTest do
  # async: false — the "429 after too many auth attempts" test accumulates global
  # rate-limiter state, so it must run in the sync phase where ConnCase's per-test
  # RateLimiter.reset() can't race its request sequence.
  use ControlPlaneWeb.ConnCase, async: false

  alias ControlPlane.Accounts

  @email "operator@example.com"
  @password "super-secret-pw-123"

  defp register_user(_) do
    {:ok, user} = Accounts.register_user(%{email: @email, password: @password, name: "Op"})
    %{user: user}
  end

  defp put_token(conn, token) do
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  describe "POST /api/v1/auth/register" do
    test "creates a user and returns a token", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{
          "email" => @email,
          "password" => @password,
          "name" => "Op"
        })

      assert %{"token" => token, "user" => user} = json_response(conn, 201)
      assert is_binary(token)
      assert user["email"] == @email
      assert user["role"] == "user"
      refute Map.has_key?(user, "hashed_password")
      refute Map.has_key?(user, "password")
    end

    test "returns 422 for a short password", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/register", %{"email" => @email, "password" => "short"})

      assert %{"errors" => %{"password" => [_ | _]}} = json_response(conn, 422)
    end
  end

  describe "POST /api/v1/auth/login" do
    setup [:register_user]

    test "returns a token for valid credentials", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/login", %{"email" => @email, "password" => @password})
      assert %{"token" => token} = json_response(conn, 200)
      assert is_binary(token)
    end

    test "returns 401 for a wrong password", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/auth/login", %{"email" => @email, "password" => "wrong-password-x"})

      assert %{"error" => _} = json_response(conn, 401)
    end
  end

  describe "GET /api/v1/auth/me" do
    setup [:register_user]

    test "returns 401 without a token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/auth/me")
      assert %{"error" => "unauthorized"} = json_response(conn, 401)
    end

    test "returns the current user with a token", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)

      conn = conn |> put_token(token) |> get(~p"/api/v1/auth/me")
      assert %{"user" => %{"id" => id, "email" => @email}} = json_response(conn, 200)
      assert id == user.id
    end
  end

  describe "DELETE /api/v1/auth/logout" do
    setup [:register_user]

    test "revokes the session so subsequent requests are unauthorized", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)

      logout_conn = conn |> put_token(token) |> delete(~p"/api/v1/auth/logout")
      assert response(logout_conn, 204)

      me_conn = build_conn() |> put_token(token) |> get(~p"/api/v1/auth/me")
      assert json_response(me_conn, 401)
    end
  end

  describe "rate limiting" do
    # CF-Connecting-IP, not X-Forwarded-For: ControlPlaneWeb.Plugs.RateLimit keys
    # its bucket on the Cloudflare header and deliberately ignores the
    # client-supplied X-Forwarded-For (which would hand an attacker unlimited
    # buckets). Sending the header the plug actually reads gives this test its own
    # counter bucket, away from the 127.0.0.1 that every other test hits — belt and
    # braces on top of ConnCase's per-test RateLimiter.reset().
    defp hammer_login(ip) do
      build_conn()
      |> put_req_header("cf-connecting-ip", ip)
      |> post(~p"/api/v1/auth/login", %{
        "email" => "nobody@example.com",
        "password" => "wrong-password-123"
      })
    end

    test "429s after too many auth attempts from one client" do
      ip = "203.0.113.7"
      # The configured limit is 30/min: the first 30 are served (401 wrong creds)...
      for _ <- 1..30, do: hammer_login(ip)
      # ...and the 31st is rejected with 429.
      assert %{"error" => "rate_limited"} = hammer_login(ip) |> json_response(429)
    end
  end

  describe "HttpOnly session cookie" do
    setup [:register_user]

    test "login sets an HttpOnly cookie that authenticates without a bearer header",
         %{conn: conn} do
      login = post(conn, ~p"/api/v1/auth/login", %{"email" => @email, "password" => @password})
      assert %{"token" => _} = json_response(login, 200)

      cookie = login.resp_cookies["bunk_session"]
      assert cookie.http_only
      assert is_binary(cookie.value) and cookie.value != ""

      # A fresh request carrying only the cookie (no Authorization header) authenticates.
      me =
        build_conn()
        |> put_req_cookie("bunk_session", cookie.value)
        |> get(~p"/api/v1/auth/me")

      assert %{"user" => %{"email" => @email}} = json_response(me, 200)
    end

    test "logout via the cookie revokes the session and clears the cookie", %{conn: conn} do
      login = post(conn, ~p"/api/v1/auth/login", %{"email" => @email, "password" => @password})
      value = login.resp_cookies["bunk_session"].value

      out =
        build_conn()
        |> put_req_cookie("bunk_session", value)
        # Zoals de browser het stuurt: zonder Origin weigert SameOrigin het.
        |> put_req_header("origin", Application.get_env(:control_plane, :public_url))
        |> delete(~p"/api/v1/auth/logout")

      assert response(out, 204)
      assert out.resp_cookies["bunk_session"].max_age == 0

      assert build_conn()
             |> put_req_cookie("bunk_session", value)
             |> get(~p"/api/v1/auth/me")
             |> json_response(401)
    end
  end

  describe "DELETE /api/v1/auth/logout/all" do
    setup [:register_user]

    test "revokes every session of the user", %{conn: conn, user: user} do
      t1 = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)
      t2 = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)

      out = conn |> put_token(t1) |> delete(~p"/api/v1/auth/logout/all")
      assert response(out, 204)

      # Both the presenting token and the other live session are now invalid.
      assert build_conn() |> put_token(t1) |> get(~p"/api/v1/auth/me") |> json_response(401)
      assert build_conn() |> put_token(t2) |> get(~p"/api/v1/auth/me") |> json_response(401)
    end
  end

  describe "POST /api/v1/auth/confirm" do
    setup [:register_user]

    test "confirms the account and returns it", %{conn: conn, user: user} do
      {:ok, token} = Accounts.deliver_user_confirmation_instructions(user)

      out = post(conn, ~p"/api/v1/auth/confirm", %{"token" => token})
      body = json_response(out, 200)
      assert body["user"]["confirmed_at"]
    end

    test "422s an invalid or expired token", %{conn: conn} do
      out = post(conn, ~p"/api/v1/auth/confirm", %{"token" => "garbage"})
      assert json_response(out, 422)["error"] == "invalid_token"
    end

    test "422s a missing token", %{conn: conn} do
      assert post(conn, ~p"/api/v1/auth/confirm", %{}) |> json_response(422)
    end
  end

  describe "POST /api/v1/auth/confirm/resend" do
    setup [:register_user]

    test "requires authentication", %{conn: conn} do
      assert conn |> post(~p"/api/v1/auth/confirm/resend", %{}) |> json_response(401)
    end

    test "sends another confirmation email for an unconfirmed user", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user) |> Base.url_encode64(padding: false)

      out = conn |> put_token(token) |> post(~p"/api/v1/auth/confirm/resend", %{})
      assert json_response(out, 200)["detail"] == "ok"
    end

    test "409s for an already-confirmed user", %{conn: conn, user: user} do
      {:ok, confirm_token} = Accounts.deliver_user_confirmation_instructions(user)
      {:ok, confirmed} = Accounts.confirm_user(confirm_token)

      session =
        Accounts.generate_user_session_token(confirmed) |> Base.url_encode64(padding: false)

      out = conn |> put_token(session) |> post(~p"/api/v1/auth/confirm/resend", %{})
      assert json_response(out, 409)["error"] == "already_confirmed"
    end
  end

  describe "POST /api/v1/auth/password-reset" do
    setup [:register_user]

    test "always returns 200, whether or not the email exists (anti-enumeration)", %{conn: conn} do
      exists = post(conn, ~p"/api/v1/auth/password-reset", %{"email" => @email})

      unknown =
        post(build_conn(), ~p"/api/v1/auth/password-reset", %{"email" => "nobody@example.com"})

      assert json_response(exists, 200) == json_response(unknown, 200)
    end

    test "429s after too many requests from one client (tighter than the general auth bucket)", %{
      conn: conn
    } do
      # The configured limit is 5/min: the first 5 are served...
      for _ <- 1..5, do: post(conn, ~p"/api/v1/auth/password-reset", %{"email" => @email})
      # ...and the 6th is rejected with 429.
      out = post(conn, ~p"/api/v1/auth/password-reset", %{"email" => @email})
      assert json_response(out, 429)["error"] == "rate_limited"
    end
  end

  describe "POST /api/v1/auth/password-reset/confirm" do
    setup [:register_user]

    test "resets the password with a valid token", %{conn: conn, user: user} do
      {:ok, token} = Accounts.deliver_user_reset_password_instructions(user)

      out =
        post(conn, ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => token,
          "password" => "a-brand-new-password-123"
        })

      assert json_response(out, 200)["detail"] == "ok"

      login =
        conn
        |> post(~p"/api/v1/auth/login", %{
          "email" => @email,
          "password" => "a-brand-new-password-123"
        })

      assert json_response(login, 200)["token"]
    end

    test "422s an invalid token", %{conn: conn} do
      out =
        post(conn, ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => "garbage",
          "password" => "a-brand-new-password-123"
        })

      assert json_response(out, 422)["error"] == "invalid_token"
    end

    test "422s a too-short password without burning the token", %{conn: conn, user: user} do
      {:ok, token} = Accounts.deliver_user_reset_password_instructions(user)

      out =
        post(conn, ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => token,
          "password" => "short"
        })

      assert json_response(out, 422)["errors"]

      # The token survives a rejected attempt, so the user can retry with a
      # stronger password using the SAME link.
      retry =
        post(conn, ~p"/api/v1/auth/password-reset/confirm", %{
          "token" => token,
          "password" => "a-brand-new-password-123"
        })

      assert json_response(retry, 200)["detail"] == "ok"
    end
  end
end
