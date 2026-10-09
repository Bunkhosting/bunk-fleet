defmodule ControlPlaneWeb.Plugs.SameOriginTest do
  @moduledoc """
  Een wijzigend verzoek op de sessiecookie moet van ons eigen dashboard komen.

  `SameSite=Lax` beschermt alleen tegen andere sites. Een andere host onder
  bunkhosting.nl is voor de browser dezelfde site, en vanaf zo'n pagina kon een
  formulier met de cookie van een ingelogde beheerder iemand beheerder maken.
  """
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Accounts

  setup do
    user = ControlPlane.Fixtures.confirmed_user_fixture()
    token = Accounts.generate_user_session_token(user)
    cookie = Base.url_encode64(token, padding: false)
    %{cookie: cookie, eigen: Application.get_env(:control_plane, :public_url)}
  end

  defp met_cookie(cookie), do: build_conn() |> put_req_cookie("bunk_session", cookie)

  defp sessie_leeft?(cookie),
    do: met_cookie(cookie) |> get(~p"/api/v1/auth/me") |> Map.fetch!(:status) == 200

  test "een andere herkomst wordt geweigerd en de sessie blijft heel", %{cookie: cookie} do
    conn =
      met_cookie(cookie)
      |> put_req_header("origin", "https://evil.bunkhosting.nl")
      |> delete(~p"/api/v1/auth/logout/all")

    assert %{"error" => "cross_origin_request"} = json_response(conn, 403)
    assert sessie_leeft?(cookie)
  end

  test "zonder Origin en Referer wordt geweigerd", %{cookie: cookie} do
    conn = met_cookie(cookie) |> delete(~p"/api/v1/auth/logout/all")
    assert json_response(conn, 403)
    assert sessie_leeft?(cookie)
  end

  test "het eigen dashboard komt erdoor", %{cookie: cookie, eigen: eigen} do
    # De tegenproef: zonder deze slaagden de weigeringen hierboven ook als de
    # route om een heel andere reden kapot was.
    conn =
      met_cookie(cookie) |> put_req_header("origin", eigen) |> delete(~p"/api/v1/auth/logout/all")

    assert conn.status in [200, 204]
    refute sessie_leeft?(cookie)
  end

  test "een Referer van het eigen dashboard volstaat als Origin ontbreekt", %{
    cookie: cookie,
    eigen: eigen
  } do
    conn =
      met_cookie(cookie)
      |> put_req_header("referer", eigen <> "/dashboard/beveiliging")
      |> delete(~p"/api/v1/auth/logout/all")

    assert conn.status in [200, 204]
  end

  test "een Bearer-header heeft geen Origin nodig", %{cookie: cookie} do
    # Agents, scripts en de e2e-harnas. Een andere site kan deze header niet
    # zetten, dus hier valt niets te vervalsen.
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> cookie)
      |> delete(~p"/api/v1/auth/logout/all")

    assert conn.status in [200, 204]
  end

  test "lezen gaat zonder Origin", %{cookie: cookie} do
    assert sessie_leeft?(cookie)
  end

  test "de beheer-API en het opwaarderen staan er ook achter", %{cookie: cookie} do
    # Hier zat de schade: tegoed geven en rollen wijzigen. Geweigerd vóór de
    # authenticatie, dus de code zegt dat de plug in die pipelines zit.
    for {methode, pad} <- [
          {:post, "/api/v1/beheer/users/#{Ecto.UUID.generate()}/credit"},
          {:patch, "/api/v1/beheer/users/#{Ecto.UUID.generate()}"},
          {:post, "/api/v1/billing/topup"}
        ] do
      conn =
        met_cookie(cookie)
        |> put_req_header("origin", "https://evil.bunkhosting.nl")
        |> dispatch(@endpoint, methode, pad, %{})

      assert %{"error" => "cross_origin_request"} = json_response(conn, 403), pad
    end
  end
end
