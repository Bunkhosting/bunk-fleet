defmodule ControlPlaneWeb.AuthController do
  @moduledoc """
  End-user/operator authentication API.

    * `POST   /api/v1/auth/register`            — create a user, return it plus a session token.
    * `POST   /api/v1/auth/login`               — exchange email + password for a session token.
    * `GET    /api/v1/auth/me`                  — (authenticated) the current user.
    * `DELETE /api/v1/auth/logout`               — (authenticated) revoke the presented session.
    * `POST   /api/v1/auth/confirm`              — exchange an email-confirmation token for a confirmed account.
    * `POST   /api/v1/auth/confirm/resend`       — (authenticated) re-send the confirmation email.
    * `POST   /api/v1/auth/password-reset`       — request a reset email (always 200; anti-enumeration).
    * `POST   /api/v1/auth/password-reset/confirm` — exchange a reset token + new password for a changed password.

  Session tokens are returned as URL-safe Base64 (no padding) and expected back the
  same way in the `Authorization: Bearer <token>` header (see
  `ControlPlaneWeb.Plugs.ApiAuth`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Accounts
  alias ControlPlaneWeb.Fouten
  alias ControlPlaneWeb.Plugs.Bearer

  # 7-day HttpOnly session cookie (matches the token's own lifetime).
  @session_cookie_max_age 60 * 60 * 24 * 7

  def register(conn, params) do
    # Verify the CAPTCHA server-side BEFORE creating an account (and granting the
    # signup bonus). Without this a bot skips the browser widget by calling the API
    # directly and farms free wallets. No-op until TURNSTILE_SECRET_KEY is set.
    with :ok <- ControlPlane.Turnstile.verify(params["turnstile_token"], client_ip(conn)),
         {:ok, user} <- Accounts.register_user(params) do
      ControlPlane.Metrics.count(:registrations)
      token = Accounts.generate_user_session_token(user)

      conn
      |> put_session_cookie(token)
      |> put_status(:created)
      |> json(%{user: user_json(user), token: encode_token(token)})
    else
      {:error, reason}
      when reason in [:captcha_required, :captcha_failed, :captcha_unavailable] ->
        # A refusal here is either a bot being stopped or a misconfiguration that
        # blocks every real customer. Turnstile.note_rejection/1 is what makes the
        # second one visible to a person instead of only to the log.
        ControlPlane.Turnstile.note_rejection(reason)
        ControlPlane.Metrics.count(:captcha_refusals)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "captcha_failed", turnstile_required: true})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  # Real client IP: Cloudflare sets CF-Connecting-IP; fall back to the peer.
  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "cf-connecting-ip") do
      [ip | _] when is_binary(ip) and ip != "" -> ip
      _ -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  def login(conn, %{"email" => email, "password" => password} = params)
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %Accounts.User{} = user ->
        # SECURITY: when 2FA is active, never issue a session token on password
        # alone — require a valid TOTP code (matches the browser MFA flow). The
        # client first calls without a code, gets {totp_required: true}, then
        # retries with the code.
        totp = Accounts.totp_active?(user)

        case second_factor(user, totp, params) do
          :ok ->
            issue_session(conn, user)

          :prompt ->
            conn |> put_status(:ok) |> json(mfa_prompt(user, totp, nil))

          {:error, code} ->
            conn |> put_status(:unauthorized) |> json(mfa_prompt(user, totp, code))
        end

      nil ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_credentials", detail: "E-mailadres of wachtwoord klopt niet."})
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "missing_credentials", detail: "email and password are required"})
  end

  defp issue_session(conn, user) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> put_session_cookie(token)
    |> put_status(:ok)
    |> json(%{user: user_json(user), token: encode_token(token)})
  end

  def me(conn, _params) do
    json(conn, %{user: user_json(conn.assigns.current_user)})
  end

  @doc """
  Confirms an account from the token in a `?token=` verification link.

  The two failure modes get deliberately different statuses, because they ask
  the user for deliberately different things. A bad or expired link is a client
  error (422): the fix is to request a new one. A confirmation that failed to
  write is ours (500): the link is still valid and retrying is the right move —
  answering 422 there would send the user round the resend loop chasing a link
  that was never the problem, and would hide an outage behind a UI that looks
  like normal user error.
  """
  def confirm(conn, %{"token" => token}) when is_binary(token) do
    case Accounts.confirm_user(token) do
      {:ok, user} ->
        json(conn, %{user: user_json(user)})

      {:error, :invalid_token} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_token", detail: "Deze link is ongeldig of verlopen."})

      {:error, :confirmation_failed} ->
        detail =
          "Bevestigen lukte even niet door een storing aan onze kant. " <>
            "Je link blijft geldig — probeer het zo nog eens."

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "confirmation_failed", detail: detail})
    end
  end

  def confirm(conn, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "missing_token", detail: "token is required"})

  @doc """
  Re-sends the confirmation email to the authenticated (already logged-in but
  unconfirmed) user. Authenticated rather than taking a bare email, so this
  can't be used to spam an arbitrary address.
  """
  def resend_confirmation(conn, _params) do
    case Accounts.deliver_user_confirmation_instructions(conn.assigns.current_user) do
      {:ok, _token} ->
        json(conn, %{detail: "ok"})

      {:error, :already_confirmed} ->
        conn |> put_status(:conflict) |> json(%{error: "already_confirmed"})
    end
  end

  @doc """
  Requests a password-reset email. Always returns 200 with an identical body
  whether or not `email` matches an account — the anti-enumeration contract is
  "if the address exists, a link was sent", so this endpoint must never leak
  which branch it took via status code, timing-sensitive DB work, or body shape.
  """
  def request_password_reset(conn, %{"email" => email}) when is_binary(email) do
    :ok = Accounts.request_password_reset(email)
    json(conn, %{detail: "ok"})
  end

  def request_password_reset(conn, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "missing_email", detail: "email is required"})

  @doc """
  Exchanges a password-reset token + new password for a changed password.

  A rejected attempt must NOT burn the token: someone who picks a password the
  policy refuses has done nothing wrong and has to be able to retry with the
  same link (their only copy of it) instead of starting the whole flow over.
  That property lives in `Accounts.reset_user_password/2`, which only deletes
  the reset + session tokens inside the transaction that also writes the new
  password — so a changeset failure rolls the deletion back with it. Nothing
  here may pre-consume the token ahead of that call.
  """
  def reset_password(conn, %{"token" => token, "password" => password})
      when is_binary(token) and is_binary(password) do
    with %Accounts.User{} = user <- Accounts.get_user_by_reset_password_token(token),
         {:ok, _user} <- Accounts.reset_user_password(user, %{"password" => password}) do
      json(conn, %{detail: "ok"})
    else
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_token", detail: "Deze link is ongeldig of verlopen."})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def reset_password(conn, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "missing_token_or_password", detail: "token and password are required"})

  def logout(conn, _params) do
    # Extract from header OR the HttpOnly cookie so a cookie-based browser session
    # revokes the exact token it presented, then always clear the cookie.
    with {:ok, encoded} <- Bearer.session_token(conn),
         {:ok, token} <- Base.url_decode64(encoded, padding: false) do
      Accounts.delete_user_session_token(token)
    end

    conn
    |> delete_resp_cookie(Bearer.cookie_name(), Bearer.cookie_options())
    |> send_resp(:no_content, "")
  end

  @doc """
  Wijzigt het wachtwoord van de ingelogde gebruiker.

  Het huidige wachtwoord moet erbij. Een geldige sessie is hier niet genoeg
  bewijs: wie een sessie in handen krijgt mag daarmee niet het account overnemen
  door het wachtwoord te wijzigen.

  Alle andere sessies vallen om; deze blijft staan. Wie zijn wachtwoord wijzigt
  omdat hij vermoedt dat iemand meekijkt, hoort daar niet zelf voor uitgelogd te
  worden -- de meekijker wel.
  """
  def change_password(conn, %{"current_password" => huidig, "password" => nieuw})
      when is_binary(huidig) and is_binary(nieuw) do
    user = conn.assigns.current_user

    case Accounts.change_user_password(
           user,
           huidig,
           %{"password" => nieuw},
           conn.assigns[:current_session_token]
         ) do
      {:ok, _bijgewerkt} ->
        json(conn, %{detail: "ok"})

      {:error, :invalid_current_password} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_credentials"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_password", errors: changeset_errors(changeset)})
    end
  end

  def change_password(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_password"})

  @doc """
  Revokes every session of the authenticated user ("log out everywhere"), giving a
  kill switch for a leaked token without DB surgery.
  """
  def logout_all(conn, _params) do
    Accounts.delete_all_user_session_tokens(conn.assigns.current_user)
    send_resp(conn, :no_content, "")
  end

  # --- helpers --------------------------------------------------------------

  defp encode_token(token), do: Base.url_encode64(token, padding: false)

  # Sets the session token as an HttpOnly cookie so the browser holds it out of
  # JS reach (an XSS foothold can't read it). Same-site Lax + Secure (over https)
  # for CSRF/transport safety. API clients keep using the returned bearer token.
  defp put_session_cookie(conn, token) do
    put_resp_cookie(
      conn,
      Bearer.cookie_name(),
      encode_token(token),
      Keyword.put(Bearer.cookie_options(), :max_age, @session_cookie_max_age)
    )
  end

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      role: user.role,
      confirmed_at: user.confirmed_at,
      totp_enabled: not is_nil(user.totp_confirmed_at),
      passkeys_enabled: Accounts.passkeys_active?(user),
      # Of deze gebruiker hardware beheert. Het dashboard toont het nodescherm
      # alleen dan: een klant die geen node heeft hoeft geen leeg scherm in zijn
      # menu, en een operator die er wel een heeft moet hem kunnen vinden zonder
      # het pad te kennen.
      owns_nodes: Accounts.owns_nodes?(user),
      inserted_at: user.inserted_at
    }
  end

  # Beslist wat het wachtwoord alleen waard is. :ok = sessie uitgeven; :prompt =
  # tweede factor vragen; {:error, code} = een poging tot tweede factor faalde.
  # Bij een mislukte passkey gaat er een nieuwe challenge mee terug (zie
  # mfa_prompt/3): de oude is verbruikt en zonder nieuwe is een volgende poging
  # kansloos.
  defp second_factor(user, totp, params) do
    cond do
      not totp and not Accounts.passkeys_active?(user) -> :ok
      totp_ok?(user, totp, params["code"]) -> :ok
      # Geen aparte passkeys_active?-check: een assertie voor een account
      # zonder passkeys strandt in finish_passkey_login op de opzoeking, met
      # hetzelfde antwoord als een verkeerde handtekening.
      is_map(params["passkey"]) -> passkey_result(user, params["passkey"])
      is_binary(params["code"]) -> {:error, "invalid_code"}
      true -> :prompt
    end
  end

  defp totp_ok?(user, true, code) when is_binary(code), do: Accounts.valid_totp?(user, code)
  defp totp_ok?(_user, _totp, _code), do: false

  defp passkey_result(user, assertion) do
    case passkey_login(user, assertion) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "invalid_passkey"}
    end
  end

  # Wat de client te zien krijgt als het wachtwoord klopt maar een tweede factor
  # nodig is. `totp_required` blijft staan voor de bestaande client; daarnaast
  # zegt `methods` welke factoren dit account heeft, en als er passkeys zijn gaat
  # de challenge meteen mee zodat de browser er niet nog een rondje voor hoeft.
  defp mfa_prompt(user, totp, error) do
    passkey = Accounts.start_passkey_login(user)

    %{
      mfa_required: true,
      totp_required: totp,
      methods: Enum.reject([if(totp, do: "totp"), if(passkey, do: "passkey")], &is_nil/1),
      passkey_challenge: passkey
    }
    |> then(fn m -> if error, do: Map.put(m, :error, error), else: m end)
  end

  defp passkey_login(user, %{"challenge_id" => cid} = p) when is_binary(cid) do
    with {:ok, credential_id} <- b64(p["id"]),
         {:ok, authenticator_data} <- b64(get_in(p, ["response", "authenticatorData"])),
         {:ok, signature} <- b64(get_in(p, ["response", "signature"])),
         {:ok, client_data_json} <- b64(get_in(p, ["response", "clientDataJSON"])) do
      Accounts.finish_passkey_login(user, cid, %{
        credential_id: credential_id,
        authenticator_data: authenticator_data,
        signature: signature,
        client_data_json: client_data_json
      })
    else
      _ -> {:error, :invalid_passkey}
    end
  end

  defp passkey_login(_user, _), do: {:error, :invalid_passkey}

  # De browser levert alles base64url zonder padding; alles wat niet decodeert
  # is geen geldig antwoord en hoeft niet verder gelezen te worden.
  defp b64(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp b64(_), do: :error

  # --- Passkeys (WebAuthn) ----------------------------------------------------

  def passkeys_list(conn, _params) do
    keys = Accounts.list_passkeys(conn.assigns.current_user)
    json(conn, %{passkeys: Enum.map(keys, &passkey_json/1)})
  end

  def passkey_register_challenge(conn, _params) do
    json(conn, Accounts.start_passkey_registration(conn.assigns.current_user))
  end

  def passkey_register(conn, %{"challenge_id" => cid, "credential" => cred} = params)
      when is_binary(cid) and is_map(cred) do
    label = String.trim(to_string(params["label"] || "Passkey"))

    with {:ok, attestation_object} <- b64(get_in(cred, ["response", "attestationObject"])),
         {:ok, client_data_json} <- b64(get_in(cred, ["response", "clientDataJSON"])),
         {:ok, pk} <-
           Accounts.finish_passkey_registration(conn.assigns.current_user, cid, %{
             attestation_object: attestation_object,
             client_data_json: client_data_json,
             label: label
           }) do
      conn |> put_status(:created) |> json(%{passkey: passkey_json(pk)})
    else
      {:error, :challenge_expired} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "challenge_expired"})

      # Alles wat hier verder uit komt is één ding: deze passkey deugt niet. Dat
      # is geen gat in de tabel maar de betekenis van dit endpoint, en daarom
      # zegt de aanroeper dat hier in plaats van dat er een 500 uit rolt.
      anders ->
        Fouten.fout(conn, anders,
          changeset_code: "invalid_passkey",
          onbekend: {:unprocessable_entity, "invalid_passkey"}
        )
    end
  end

  def passkey_register(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_passkey"})

  def passkey_delete(conn, %{"id" => id}) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Accounts.delete_passkey(conn.assigns.current_user, uuid) do
          {:ok, _} -> send_resp(conn, :no_content, "")
          {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "not_found"})
        end

      :error ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp passkey_json(pk) do
    %{
      id: pk.id,
      label: pk.label,
      created_at: pk.inserted_at,
      last_used_at: pk.last_used_at
    }
  end

  # --- TOTP (two-factor) — exposes bunk-fleet's own Accounts TOTP feature -----

  @doc "Starts TOTP setup: persists a fresh secret and returns it + a QR data URL."
  def totp_setup(conn, _params) do
    case Accounts.start_totp_setup(conn.assigns.current_user) do
      {:error, :already_enabled} ->
        conn |> put_status(:conflict) |> json(%{error: "totp_already_enabled"})

      user ->
        json(conn, %{
          secret: Accounts.totp_secret_base32(user),
          qr_data_url: qr_data_url(Accounts.totp_uri(user))
        })
    end
  end

  @doc "Confirms TOTP setup with a code from the authenticator app."
  def totp_confirm(conn, %{"code" => code}) when is_binary(code) do
    case Accounts.confirm_totp(conn.assigns.current_user, code) do
      {:ok, _user} -> json(conn, %{detail: "ok"})
      {:error, _} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_code"})
    end
  end

  def totp_confirm(conn, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "missing_code", detail: "code is required"})

  @doc "Disables TOTP — requires a valid current code (defence in depth)."
  def totp_disable(conn, %{"code" => code}) when is_binary(code) do
    user = conn.assigns.current_user

    if Accounts.valid_totp?(user, code) do
      {:ok, _} = Accounts.disable_totp(user)
      json(conn, %{detail: "ok"})
    else
      conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_code"})
    end
  end

  def totp_disable(conn, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "missing_code", detail: "code is required"})

  defp qr_data_url(uri) do
    svg = uri |> EQRCode.encode() |> EQRCode.svg(width: 200)
    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
