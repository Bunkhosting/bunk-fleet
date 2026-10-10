defmodule ControlPlaneWeb.UserSessionController do
  use ControlPlaneWeb, :controller

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.LoginThrottle
  alias ControlPlaneWeb.UserAuth

  def new(conn, _params) do
    conn
    |> put_layout(html: false)
    |> render(:new, error: nil)
  end

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %Accounts.User{} = user ->
        cond do
          # Dit scherm kent geen passkeys. Een account dat alleen een passkey als
          # tweede factor heeft, kwam hier eerst binnen met alleen een
          # wachtwoord -- precies wat die passkey moest voorkomen.
          not Accounts.totp_active?(user) and Accounts.passkeys_active?(user) ->
            conn
            |> put_layout(html: false)
            |> put_status(:unauthorized)
            |> render(:new,
              error:
                "Dit account logt in met een passkey. Gebruik het dashboard op app.bunkhosting.nl."
            )

          Accounts.totp_active?(user) ->
            # Password verified, but the account requires a second factor. Hold the
            # user id in a fresh session WITHOUT issuing an auth token yet.
            conn
            |> configure_session(renew: true)
            |> put_session(:mfa_pending_user_id, user.id)
            |> redirect(to: ~p"/login/mfa")

          true ->
            conn
            |> put_flash(:info, "Welkom terug!")
            |> UserAuth.log_in_user(user)
        end

      nil ->
        conn
        |> put_layout(html: false)
        |> put_status(:unauthorized)
        |> render(:new, error: "Ongeldig e-mailadres of wachtwoord.")
    end
  end

  def mfa_new(conn, _params) do
    if get_session(conn, :mfa_pending_user_id) do
      conn |> put_layout(html: false) |> render(:mfa, error: nil)
    else
      redirect(conn, to: ~p"/login")
    end
  end

  def mfa_create(conn, %{"totp" => %{"code" => code}}) do
    user = get_session(conn, :mfa_pending_user_id) |> load_pending_user()

    cond do
      is_nil(user) ->
        redirect(conn, to: ~p"/login")

      # Dezelfde teller per account als de API (AuthController.second_factor/3):
      # zonder die was dit scherm de route om een code te raden.
      LoginThrottle.blocked?("2fa:" <> user.email) ->
        ongeldige_code(conn)

      Accounts.valid_totp?(user, code) ->
        LoginThrottle.clear("2fa:" <> user.email)

        conn
        |> delete_session(:mfa_pending_user_id)
        |> put_flash(:info, "Welkom terug!")
        |> UserAuth.log_in_user(user, mfa: true)

      true ->
        LoginThrottle.note_failure("2fa:" <> user.email)
        ongeldige_code(conn)
    end
  end

  def mfa_create(conn, _params), do: redirect(conn, to: ~p"/login/mfa")

  defp ongeldige_code(conn) do
    conn
    |> put_layout(html: false)
    |> put_status(:unauthorized)
    |> render(:mfa, error: "Ongeldige code. Probeer opnieuw.")
  end

  defp load_pending_user(nil), do: nil
  defp load_pending_user(id), do: Accounts.get_user(id)

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Je bent uitgelogd.")
    |> UserAuth.log_out_user()
  end
end
