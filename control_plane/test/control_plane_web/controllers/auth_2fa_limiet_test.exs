defmodule ControlPlaneWeb.Auth2faLimietTest do
  @moduledoc """
  Foute 2FA-codes tellen per account, niet alleen per IP-adres.

  Met alleen een limiet per adres was een gelekt wachtwoord plus genoeg adressen
  genoeg om de code te raden: elk goed wachtwoord zette de wachtwoordteller
  terug, en elke aanvraag mocht een verse code proberen.
  """
  use ControlPlaneWeb.ConnCase, async: false

  import ControlPlane.Fixtures

  alias ControlPlane.Accounts.LoginThrottle
  alias ControlPlane.Repo

  @wachtwoord "lang-genoeg-wachtwoord-voor-de-test"

  setup do
    geheim = NimbleTOTP.secret()

    user =
      confirmed_user_fixture(%{password: @wachtwoord})
      |> Ecto.Changeset.change(
        totp_secret: geheim,
        totp_confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
      |> Repo.update!()

    %{user: user, geheim: geheim}
  end

  # Elke poging vanaf een ander adres, zoals een aanvaller met een botnet doet:
  # de limiet per IP grijpt dan nooit.
  defp inloggen(user, code, n) do
    build_conn()
    |> put_req_header("cf-connecting-ip", "198.51.100.#{rem(n, 250) + 1}")
    |> post(~p"/api/v1/auth/login", %{
      "email" => user.email,
      "password" => @wachtwoord,
      "code" => code
    })
  end

  test "na vijf foute codes helpt ook de goede code even niet", %{user: user, geheim: geheim} do
    for n <- 1..5, do: assert(inloggen(user, "000000", n).status == 401)

    conn = inloggen(user, NimbleTOTP.verification_code(geheim), 99)
    assert %{"error" => "invalid_code"} = json_response(conn, 401)
  end

  test "de goede code werkt gewoon zolang de grens niet bereikt is", %{user: user, geheim: geheim} do
    # De tegenproef: zonder deze slaagde de test hierboven ook als inloggen met
    # 2FA in deze opzet altijd mislukte.
    for n <- 1..4, do: assert(inloggen(user, "000000", n).status == 401)

    assert %{"token" => _} =
             json_response(inloggen(user, NimbleTOTP.verification_code(geheim), 99), 200)
  end

  test "een geslaagde login zet de teller terug", %{user: user, geheim: geheim} do
    for n <- 1..4, do: inloggen(user, "000000", n)
    assert inloggen(user, NimbleTOTP.verification_code(geheim), 50).status == 200

    # Vier nieuwe missers. Zonder terugzetten staan er dan acht, en is het
    # account al geblokkeerd. Aan de teller zelf afgelezen: dezelfde code een
    # tweede keer gebruiken wordt terecht geweigerd (hergebruik), dus een
    # tweede login binnen dertig seconden zegt hier niets.
    for n <- 1..4, do: inloggen(user, "000000", 100 + n)

    refute LoginThrottle.blocked?("2fa:" <> user.email)
  end
end
