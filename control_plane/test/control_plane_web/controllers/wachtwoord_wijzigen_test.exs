defmodule ControlPlaneWeb.WachtwoordWijzigenTest do
  @moduledoc """
  Je wachtwoord wijzigen terwijl je bent ingelogd.

  Dit ontbrak: de enige weg naar een nieuw wachtwoord liep via "wachtwoord
  vergeten" en een mailtje. Wie vermoedt dat iemand meekijkt hoort dat ter
  plekke te kunnen afsluiten, en wie een sessie in handen krijgt hoort er juist
  géén account mee over te kunnen nemen. Die twee eisen zitten hier tegenover
  elkaar en daarom staan ze allebei in een test.
  """
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Accounts

  @oud "Str0ngPassphrase!42"
  @nieuw "Nog-Str0nger!2026"

  defp gebruiker do
    email = "wachtwoord-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: @oud})
    u
  end

  defp sessie(user) do
    user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
  end

  defp met(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  test "het wachtwoord verandert echt", %{conn: conn} do
    u = gebruiker()

    conn
    |> met(sessie(u))
    |> patch(~p"/api/v1/auth/password", %{"current_password" => @oud, "password" => @nieuw})
    |> json_response(200)

    assert %Accounts.User{} = Accounts.get_user_by_email_and_password(u.email, @nieuw)
    refute Accounts.get_user_by_email_and_password(u.email, @oud)
  end

  test "zonder het huidige wachtwoord verandert er niets", %{conn: conn} do
    # Een gestolen sessie mag geen accountovername worden.
    u = gebruiker()

    resp =
      conn
      |> met(sessie(u))
      |> patch(~p"/api/v1/auth/password", %{
        "current_password" => "fout-fout-fout",
        "password" => @nieuw
      })
      |> json_response(422)

    assert resp["error"] == "wrong_current_password"
    assert Accounts.get_user_by_email_and_password(u.email, @oud)
  end

  test "een te zwak nieuw wachtwoord wordt geweigerd met de reden", %{conn: conn} do
    u = gebruiker()

    resp =
      conn
      |> met(sessie(u))
      |> patch(~p"/api/v1/auth/password", %{"current_password" => @oud, "password" => "kort"})
      |> json_response(422)

    assert resp["error"] == "weak_password"
    assert resp["errors"]["password"]
    assert Accounts.get_user_by_email_and_password(u.email, @oud)
  end

  test "andere sessies vallen om, de eigen blijft staan", %{conn: conn} do
    # Dit is de hele reden dat iemand dit doet: de meekijker eruit, jezelf niet.
    u = gebruiker()
    mijn = sessie(u)
    andere = sessie(u)

    conn
    |> met(mijn)
    |> patch(~p"/api/v1/auth/password", %{"current_password" => @oud, "password" => @nieuw})
    |> json_response(200)

    assert conn |> met(mijn) |> get(~p"/api/v1/auth/me") |> json_response(200)
    assert conn |> met(andere) |> get(~p"/api/v1/auth/me") |> json_response(401)
  end

  test "zonder sessie: 401", %{conn: conn} do
    assert conn
           |> patch(~p"/api/v1/auth/password", %{"current_password" => @oud, "password" => @nieuw})
           |> json_response(401)
  end

  test "ontbrekende velden geven 422 en geen 500", %{conn: conn} do
    u = gebruiker()

    assert conn |> met(sessie(u)) |> patch(~p"/api/v1/auth/password", %{}) |> json_response(422)
    assert Accounts.get_user_by_email_and_password(u.email, @oud)
  end
end
