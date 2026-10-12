defmodule ControlPlane.Accounts.Totp do
  @moduledoc """
  De authenticator-app als tweede factor (TOTP).

  Instellen gaat in twee stappen: `start_totp_setup/1` zet een nog onbevestigd
  geheim klaar en `confirm_totp/2` maakt het pas actief zodra er een geldige
  code mee terugkomt. Bij het inloggen controleert `valid_totp?/2` de code en
  claimt het tijdvak, zodat dezelfde code binnen zijn venster niet nog eens
  bruikbaar is. `totp_uri/1` en `totp_secret_base32/1` leveren wat de
  authenticator-app nodig heeft om het geheim over te nemen.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Accounts.User
  alias ControlPlane.Clock
  alias ControlPlane.Repo

  @doc "True once the user has set up AND confirmed a TOTP authenticator."
  def totp_active?(%User{totp_confirmed_at: nil}), do: false
  def totp_active?(%User{totp_secret: secret}) when is_binary(secret), do: true
  def totp_active?(_), do: false

  # Refuse to reset a VPS owner who has ALREADY confirmed 2FA: overwriting the
  # secret here would silently disable their working authenticator. Combined with
  # cookie auth + SameSite=Lax (which still attaches the cookie on a top-level GET
  # navigation), an attacker could otherwise CSRF a victim into losing 2FA. To
  # re-enrol they must first disable it, which requires a valid current code.
  @doc "Generates a fresh (unconfirmed) TOTP secret for the user and persists it."
  def start_totp_setup(%User{totp_confirmed_at: confirmed}) when not is_nil(confirmed),
    do: {:error, :already_enabled}

  def start_totp_setup(%User{} = user) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change(totp_secret: NimbleTOTP.secret(), totp_confirmed_at: nil)
      |> Repo.update()

    user
  end

  @doc "Confirms TOTP setup by verifying a code against the pending secret."
  def confirm_totp(%User{totp_secret: secret} = user, code) when is_binary(secret) do
    if valid_totp_code?(secret, code) do
      user
      |> Ecto.Changeset.change(totp_confirmed_at: Clock.now())
      |> Repo.update()
    else
      {:error, :invalid_code}
    end
  end

  def confirm_totp(_user, _code), do: {:error, :invalid_code}

  @doc "Disables TOTP (also cancels an unconfirmed setup), clearing the secret."
  def disable_totp(%User{} = user) do
    user
    |> Ecto.Changeset.change(totp_secret: nil, totp_confirmed_at: nil)
    |> Repo.update()
  end

  @doc """
  Validates a login TOTP code for an MFA-active user, single-use per time-step:
  on success the accepted step is recorded (`since:`) so the same 6-digit code
  can't be replayed within its ~30s window (a stolen-then-reused code is dead).
  """
  def valid_totp?(%User{totp_secret: secret} = user, code) when is_binary(secret) do
    trimmed = String.trim(to_string(code))

    now = Clock.now()

    if byte_size(trimmed) == 6 and
         NimbleTOTP.valid?(secret, trimmed, since: user.totp_last_used_at) do
      # Atomically claim this time-step so a valid code cannot be replayed, even
      # under concurrent requests: only the write that advances the watermark
      # wins (1 row affected). Previously the update result was discarded
      # fire-and-forget, so a failed/lost write (or a race) left no watermark and
      # the same 6-digit code could be reused within its ~30s window.
      {count, _} =
        from(u in User,
          where:
            u.id == ^user.id and
              (is_nil(u.totp_last_used_at) or u.totp_last_used_at < ^now)
        )
        |> Repo.update_all(set: [totp_last_used_at: now])

      count == 1
    else
      false
    end
  end

  def valid_totp?(_user, _code), do: false

  @doc "The otpauth:// URI to encode into a QR code for authenticator apps."
  def totp_uri(%User{email: email, totp_secret: secret}) when is_binary(secret),
    do: NimbleTOTP.otpauth_uri("Bunk:" <> email, secret, issuer: "Bunk")

  @doc "The base32 secret for manual entry into an authenticator app."
  def totp_secret_base32(%User{totp_secret: secret}) when is_binary(secret),
    do: Base.encode32(secret, padding: false)

  defp valid_totp_code?(secret, code) when is_binary(code) do
    trimmed = String.trim(code)
    byte_size(trimmed) == 6 and NimbleTOTP.valid?(secret, trimmed)
  end

  defp valid_totp_code?(_secret, _code), do: false
end
