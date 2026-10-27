defmodule ControlPlaneWeb.AuthController do
  @moduledoc """
  End-user/operator authentication API.

    * `POST   /api/v1/auth/register`            — create a user, return it and set the session cookie.
    * `POST   /api/v1/auth/login`               — exchange email + password for the session cookie.
    * `GET    /api/v1/auth/me`                  — (authenticated) the current user.
    * `DELETE /api/v1/auth/logout`               — (authenticated) revoke the presented session.
    * `POST   /api/v1/auth/confirm`              — exchange an email-confirmation token for a confirmed account.
    * `POST   /api/v1/auth/confirm/resend`       — (authenticated) re-send the confirmation email.
    * `POST   /api/v1/auth/password-reset`       — request a reset email (always 200; anti-enumeration).
    * `POST   /api/v1/auth/password-reset/confirm` — exchange a reset token + new password for a changed password.

  De sessie gaat uitsluitend mee als HttpOnly-cookie `bunk_session`, nooit in de
  JSON-body. Een token in de body is leesbaar voor JavaScript en daarmee voor
  elke XSS: wat de HttpOnly-vlag op de cookie beschermt, gaf de body gewoon weg.
  Er was ook geen afnemer meer van: het dashboard leunt al op de cookie en de
  e2e-harnas leest het token uit `Set-Cookie`. Een API-client die de waarde
  toch zelf wil dragen kan hem daar ook vandaan halen en terugsturen als
  `Authorization: Bearer <token>` (zie `ControlPlaneWeb.Plugs.ApiAuth`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.Deletion
  alias ControlPlane.Accounts.LoginThrottle
  alias ControlPlane.Accounts.Passkeys
  alias ControlPlane.Accounts.Totp
  alias ControlPlaneWeb.Fouten
  alias ControlPlaneWeb.Plugs.Bearer

  # 7-day HttpOnly session cookie (matches the token's own lifetime).
  @session_cookie_max_age 60 * 60 * 24 * 7

  # Een factor toevoegen aan een account dat er al een heeft, vraagt een sessie
  # die zelf met een tweede factor begon. Anders kon wie het wachtwoord plus een
  # oude sessie had (van vóór de 2FA, of via XSS) een eigen passkey registreren,
  # opnieuw inloggen met wachtwoord en die passkey, en zo het beheerpaneel in
  # zonder ooit de echte tweede factor te tonen. De allereerste factor blijft
  # vrij: zonder factor is er niets om mee te bewijzen.
  plug :eis_factor_sessie
       when action in [:passkey_register_challenge, :passkey_register, :totp_setup, :totp_confirm]

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
      |> json(%{user: user_json(user)})
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
        totp = Totp.totp_active?(user)

        case second_factor(user, totp, params) do
          :ok ->
            # Heeft het account een tweede factor, dan heeft second_factor/3 die
            # zojuist gezien -- anders was het geen :ok. De sessie onthoudt dat;
            # het beheerpaneel vraagt erom.
            issue_session(conn, user, mfa: totp or Passkeys.passkeys_active?(user))

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

  defp issue_session(conn, user, opts) do
    token = Accounts.generate_user_session_token(user, opts)

    conn
    |> put_session_cookie(token)
    |> put_status(:ok)
    |> json(%{user: user_json(user)})
  end

  def me(conn, _params) do
    user =
      conn.assigns.current_user
      |> user_json()
      # Of DEZE sessie met een tweede factor begon. Het dashboard gebruikt het om
      # een beheerder uit te leggen waarom het paneel om een nieuwe login vraagt.
      |> Map.put(:session_mfa, Accounts.session_mfa?(conn.assigns[:current_session_token]))

    json(conn, %{user: user})
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

      # Eigen codes. Het waren invalid_credentials en invalid_password, en het
      # scherm zei bij een te kort nieuw wachtwoord "het opgegeven wachtwoord
      # klopt niet" -- de klant ging zijn huidige wachtwoord zitten controleren.
      {:error, :invalid_current_password} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "wrong_current_password"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "weak_password", errors: changeset_errors(changeset)})
    end
  end

  def change_password(conn, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "missing_password"})

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
  # for CSRF/transport safety; ControlPlaneWeb.Plugs.SameOrigin doet de rest voor
  # wijzigende verzoeken. Dit is de enige plek waar het token de server verlaat.
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
      passkeys_enabled: Passkeys.passkeys_active?(user),
      # Of deze gebruiker hardware beheert. Het dashboard toont het nodescherm
      # alleen dan: een klant die geen node heeft hoeft geen leeg scherm in zijn
      # menu, en een operator die er wel een heeft moet hem kunnen vinden zonder
      # het pad te kennen.
      owns_nodes: Deletion.owns_nodes?(user),
      inserted_at: user.inserted_at
    }
  end

  # Beslist wat het wachtwoord alleen waard is. :ok = sessie uitgeven; :prompt =
  # tweede factor vragen; {:error, code} = een poging tot tweede factor faalde.
  # Bij een mislukte passkey gaat er een nieuwe challenge mee terug (zie
  # mfa_prompt/3): de oude is verbruikt en zonder nieuwe is een volgende poging
  # kansloos.
  #
  # Foute tweede factoren tellen per account, net als foute wachtwoorden, maar
  # in een eigen teller die een goed wachtwoord NIET wist. Eerst was er alleen de
  # limiet per IP-adres: met een gelekt wachtwoord en genoeg adressen was een
  # zescijferige code in een half uur te raden, want elk goed wachtwoord zette de
  # wachtwoordteller terug. Na 20 missers is het één poging per half uur.
  defp second_factor(user, totp, params) do
    sleutel = "2fa:" <> user.email

    cond do
      not totp and not Passkeys.passkeys_active?(user) ->
        :ok

      poging?(params) and LoginThrottle.blocked?(sleutel) ->
        # Zelfde antwoord als een foute code: een herkenbare "geblokkeerd" zegt
        # een aanvaller dat hij het juiste wachtwoord heeft.
        {:error, poging_fout(params)}

      true ->
        case tweede_factor(user, totp, params) do
          :ok ->
            LoginThrottle.clear(sleutel)
            :ok

          {:error, _} = fout ->
            LoginThrottle.note_failure(sleutel)
            fout

          :prompt ->
            :prompt
        end
    end
  end

  defp poging?(params), do: is_binary(params["code"]) or is_map(params["passkey"])

  defp eis_factor_sessie(conn, _opts) do
    if Accounts.has_second_factor?(conn.assigns.current_user) and
         not Accounts.session_mfa?(conn.assigns[:current_session_token]) do
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: "reauth_required",
        detail: "Log opnieuw in met je tweede factor om er een toe te voegen."
      })
      |> halt()
    else
      conn
    end
  end

  defp poging_fout(%{"passkey" => %{}}), do: "invalid_passkey"
  defp poging_fout(_params), do: "invalid_code"

  defp tweede_factor(user, totp, params) do
    cond do
      totp_ok?(user, totp, params["code"]) -> :ok
      # Geen aparte passkeys_active?-check: een assertie voor een account
      # zonder passkeys strandt in finish_passkey_login op de opzoeking, met
      # hetzelfde antwoord als een verkeerde handtekening.
      is_map(params["passkey"]) -> passkey_result(user, params["passkey"])
      is_binary(params["code"]) -> {:error, "invalid_code"}
      true -> :prompt
    end
  end

  defp totp_ok?(user, true, code) when is_binary(code), do: Totp.valid_totp?(user, code)
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
    passkey = Passkeys.start_passkey_login(user)

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
      Passkeys.finish_passkey_login(user, cid, %{
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
    keys = Passkeys.list_passkeys(conn.assigns.current_user)
    json(conn, %{passkeys: Enum.map(keys, &passkey_json/1)})
  end

  def passkey_register_challenge(conn, _params) do
    json(conn, Passkeys.start_passkey_registration(conn.assigns.current_user))
  end

  def passkey_register(conn, %{"challenge_id" => cid, "credential" => cred} = params)
      when is_binary(cid) and is_map(cred) do
    # Alleen een string is een label. `to_string/1` op een JSON-object raist, en
    # dat was een 500 op een verzoek dat elke ingelogde gebruiker kan sturen.
    label =
      case params["label"] do
        tekst when is_binary(tekst) -> String.trim(tekst)
        _ -> "Passkey"
      end

    with {:ok, attestation_object} <- b64(get_in(cred, ["response", "attestationObject"])),
         {:ok, client_data_json} <- b64(get_in(cred, ["response", "clientDataJSON"])),
         {:ok, pk} <-
           Passkeys.finish_passkey_registration(conn.assigns.current_user, cid, %{
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

  @doc """
  Verwijdert een passkey. Het huidige wachtwoord moet erbij, net als bij
  wachtwoord wijzigen: een passkey kan de tweede factor zijn, en wie alleen een
  sessie in handen heeft mag de 2FA niet kunnen uitzetten. Zie
  `Passkeys.delete_passkey/3`.

  Dezelfde codes als bij wachtwoord wijzigen, zodat het scherm ze al kent.
  """
  def passkey_delete(conn, %{"id" => id, "current_password" => huidig})
      when is_binary(huidig) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, _} <- Passkeys.delete_passkey(conn.assigns.current_user, uuid, huidig) do
      send_resp(conn, :no_content, "")
    else
      {:error, :invalid_current_password} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "wrong_current_password"})

      # Geen uuid, niet van jou of bestaat niet: één antwoord, zodat het niet
      # verraadt welke id's van een ander zijn.
      _ ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def passkey_delete(conn, _params),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "missing_password"})

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
    case Totp.start_totp_setup(conn.assigns.current_user) do
      {:error, :already_enabled} ->
        conn |> put_status(:conflict) |> json(%{error: "totp_already_enabled"})

      user ->
        json(conn, %{
          secret: Totp.totp_secret_base32(user),
          qr_data_url: qr_data_url(Totp.totp_uri(user))
        })
    end
  end

  @doc "Confirms TOTP setup with a code from the authenticator app."
  def totp_confirm(conn, %{"code" => code}) when is_binary(code) do
    case Totp.confirm_totp(conn.assigns.current_user, code) do
      {:ok, _user} -> json(conn, %{detail: "ok"})
      {:error, _} -> conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_code"})
    end
  end

  def totp_confirm(conn, _params),
    do:
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "missing_code", detail: "code is required"})

  @doc """
  Disables TOTP — requires a valid current code (defence in depth).

  Telt mee in dezelfde `2fa:`-teller als het inloggen. Zonder die teller was dit
  de route om de code te raden: wie een sessie had, kon hier zo vaak proberen als
  de algemene limiet per gebruiker toeliet, en na een treffer zijn eigen
  authenticator aanzetten en de eigenaar buitensluiten.
  """
  def totp_disable(conn, %{"code" => code}) when is_binary(code) do
    user = conn.assigns.current_user
    sleutel = "2fa:" <> user.email

    cond do
      # Zelfde antwoord als een foute code, net als bij het inloggen.
      LoginThrottle.blocked?(sleutel) ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_code"})

      Totp.valid_totp?(user, code) ->
        LoginThrottle.clear(sleutel)
        {:ok, _} = Totp.disable_totp(user)
        json(conn, %{detail: "ok"})

      true ->
        LoginThrottle.note_failure(sleutel)
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
