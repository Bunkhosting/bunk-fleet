defmodule ControlPlaneWeb.Admin.MetricsTest do
  @moduledoc """
  The admin metrics endpoint, and the promise it makes about privacy.

  The promise is the point: this panel answers "how much", never "who". A future
  change that adds an email or an IP to any of these payloads turns an internal
  dashboard into personal-data processing that needs a legal basis and a deletion
  path, and it would do so without anything breaking. The last test in this file
  is what breaks.
  """
  use ControlPlaneWeb.ConnCase, async: false

  import ControlPlane.Fixtures, only: [with_second_factor: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Metrics
  alias ControlPlane.Repo

  @password "test-only-password-4f2b9c1e"
  @path "/api/v1/beheer/metrics"

  defp admin_conn(conn) do
    email = "metrics-admin-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})

    admin =
      user |> Ecto.Changeset.change(%{role: :admin}) |> Repo.update!() |> with_second_factor()

    token =
      admin
      |> Accounts.generate_user_session_token(mfa: true)
      |> Base.url_encode64(padding: false)

    {put_req_header(conn, "authorization", "Bearer " <> token), admin}
  end

  test "counts a successful and a failed login on today's row", %{conn: conn} do
    {authed, admin} = admin_conn(conn)

    Accounts.get_user_by_email_and_password(admin.email, @password)
    Accounts.get_user_by_email_and_password(admin.email, "wrong-on-purpose")

    today = Date.to_iso8601(Date.utc_today())

    row =
      authed
      |> get(@path)
      |> json_response(200)
      |> Map.fetch!("auth")
      |> Enum.find(&(&1["day"] == today))

    assert row["successes"] >= 1
    assert row["failures"] >= 1
  end

  test "reports fleet capacity and account totals", %{conn: conn} do
    {authed, _admin} = admin_conn(conn)

    body = authed |> get(@path) |> json_response(200)

    assert is_list(body["nodes"])
    assert is_list(body["commands"])
    assert is_list(body["backups"])
    assert body["accounts"]["total"] >= 1
    assert body["accounts"]["confirmed"] <= body["accounts"]["total"]
    assert body["accounts"]["with_2fa"] <= body["accounts"]["total"]
  end

  test "a customer cannot read it", %{conn: conn} do
    email = "metrics-user-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})

    token =
      user |> Accounts.generate_user_session_token(mfa: true) |> Base.url_encode64(padding: false)

    assert conn
           |> put_req_header("authorization", "Bearer " <> token)
           |> get(@path)
           |> json_response(403)
  end

  test "an anonymous caller cannot read it", %{conn: conn} do
    assert %{status: 401} = get(conn, @path)
  end

  test "unknown counters raise rather than counting nothing" do
    # A typo here would be a metric that reads zero forever and looks like good
    # news.
    assert_raise FunctionClauseError, fn -> Metrics.count(:typo) end
  end

  test "nothing in the payload identifies a person", %{conn: conn} do
    {authed, admin} = admin_conn(conn)

    # Give the fleet figures something to report on.
    Accounts.get_user_by_email_and_password(admin.email, @password)

    body = authed |> get(@path) |> json_response(200) |> Jason.encode!()

    refute body =~ admin.email
    refute body =~ "@"
    refute body =~ "email"
    refute body =~ "owner"
    refute body =~ "user_id"
    refute body =~ "ip_address"
  end
end
