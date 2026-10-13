defmodule ControlPlaneWeb.Admin.TopupControllerTest do
  use ControlPlaneWeb.ConnCase

  alias ControlPlane.Accounts
  alias ControlPlane.Credits
  alias ControlPlane.Credits.Topups

  # Een beheerderssessie, geen gedeeld geheim meer: zie `ConnCase.als_beheerder/1`.
  defp auth(conn), do: conn |> als_beheerder() |> elem(0)

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "test-only-password-4f2b9c1e"})
    u
  end

  test "lists pending requests", %{conn: conn} do
    u = user("at1@bunk.test")
    {:ok, _} = Topups.create_topup_request(u.id, 2500)
    body = conn |> auth() |> get(~p"/admin/v1/topups") |> json_response(200)

    assert Enum.any?(
             body["requests"],
             &(&1["email"] == "at1@bunk.test" and &1["amount_cents"] == 2500)
           )
  end

  test "confirm credits the wallet and is idempotent", %{conn: conn} do
    u = user("at2@bunk.test")
    start = Credits.balance_cents(u.id)
    {:ok, r} = Topups.create_topup_request(u.id, 2500)

    body = conn |> auth() |> post(~p"/admin/v1/topups/#{r.id}/confirm") |> json_response(200)
    assert body["status"] == "paid"
    assert body["balance_cents"] == start + 2500

    assert conn |> auth() |> post(~p"/admin/v1/topups/#{r.id}/confirm") |> json_response(409)
  end

  test "confirm unknown -> 404", %{conn: conn} do
    assert conn
           |> auth()
           |> post(~p"/admin/v1/topups/#{Ecto.UUID.generate()}/confirm")
           |> json_response(404)
  end

  test "requires an admin session", %{conn: conn} do
    u = user("at3@bunk.test")
    {:ok, r} = Topups.create_topup_request(u.id, 1000)
    conn = post(conn, ~p"/admin/v1/topups/#{r.id}/confirm")
    assert conn.status in [401, 403]
  end
end
