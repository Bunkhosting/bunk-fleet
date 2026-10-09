defmodule ControlPlaneWeb.Admin.EnrollTokenPanelTest do
  @moduledoc """
  Een node toevoegen vanuit het dashboard.

  Dit endpoint bestaat naast dat onder `/admin/v1`, omdat Cloudflare's WAF elk
  pad dat met /admin begint blokkeert voordat het de origin bereikt. Zonder deze
  route is een node toevoegen vanuit de browser onmogelijk — precies het gat dat
  deze tests dichthouden.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures, only: [with_second_factor: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.User
  alias ControlPlane.Fleet.EnrollToken
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  @password "test-only-password-4f2b9c1e"

  defp admin do
    email = "admin-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user |> Ecto.Changeset.change(%{role: :admin}) |> Repo.update!() |> with_second_factor()
  end

  defp authed(conn, %User{} = user) do
    token =
      user |> Accounts.generate_user_session_token(mfa: true) |> Base.url_encode64(padding: false)

    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp region(code) do
    Repo.insert!(%Region{code: code, name: "Regio #{code}"})
  end

  test "mint een token met een installatieregel die het token bevat", %{conn: conn} do
    region("nl-1")

    body =
      conn
      |> authed(admin())
      |> post(~p"/api/v1/beheer/enroll-tokens", %{})
      |> json_response(201)

    assert is_binary(body["enroll_token"])
    assert body["region"] == "nl-1"
    assert body["expires_at"]

    # De operator plakt deze regel op de machine; staat het token er niet in,
    # dan is het antwoord waardeloos ook al ziet het er goed uit.
    assert String.contains?(body["install"], body["enroll_token"])
    assert String.contains?(body["install"], "/install.sh")
  end

  test "de database bewaart geen leesbaar token", %{conn: conn} do
    region("nl-1")

    body =
      conn |> authed(admin()) |> post(~p"/api/v1/beheer/enroll-tokens", %{}) |> json_response(201)

    tokens = Repo.all(EnrollToken)
    assert length(tokens) == 1
    refute Enum.any?(tokens, &(&1.token_hash == body["enroll_token"]))
  end

  test "zonder regio's is het een nette 422 en geen 500", %{conn: conn} do
    assert %{"error" => "region_not_found"} =
             conn
             |> authed(admin())
             |> post(~p"/api/v1/beheer/enroll-tokens", %{})
             |> json_response(422)
  end

  test "een onbekende regiocode wordt geweigerd", %{conn: conn} do
    region("nl-1")

    assert %{"error" => "region_not_found"} =
             conn
             |> authed(admin())
             |> post(~p"/api/v1/beheer/enroll-tokens", %{"region_code" => "de-9"})
             |> json_response(422)
  end

  test "met meerdere regio's moet er gekozen worden", %{conn: conn} do
    region("nl-1")
    region("nl-2")

    # Raden zou een node in de verkeerde regio zetten, en dan krijgt een klant
    # hardware op een andere plek dan hij koos.
    #
    # En het is nadrukkelijk niet `region_not_found`: dat gaf het paneel de
    # melding "controleer of er een regio bestaat" op het moment dat er juist
    # een tweede bij was gekomen. Twee verschillende problemen met twee
    # verschillende oplossingen horen niet dezelfde code te delen.
    assert %{"error" => "region_ambiguous"} =
             conn
             |> authed(admin())
             |> post(~p"/api/v1/beheer/enroll-tokens", %{})
             |> json_response(422)

    assert %{"region" => "nl-2"} =
             conn
             |> authed(admin())
             |> post(~p"/api/v1/beheer/enroll-tokens", %{"region_code" => "nl-2"})
             |> json_response(201)
  end
end
