defmodule ControlPlaneWeb.Admin.BillingUsageTest do
  @moduledoc """
  `GET /admin/v1/billing/usage` — what the fleet's own capacity served over a
  window, per cost centre.

  This is internal cost accounting, not a customer invoice, but it is still the
  number an operator reads to decide whether a node pays for itself. Two things
  decide whether it is right: the window is half-open, so adjacent windows tile
  without counting a record twice, and the money is a Decimal serialized as a
  string rather than a float.
  """
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Billing.UsageRecord
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @path "/admin/v1/billing/usage"

  setup do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "R"})
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Repo.insert!()

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "v-#{System.unique_integer([:positive])}",
        region_id: region.id,
        node_id: node.id,
        vcpu: 2,
        ram_mb: 2048,
        disk_gb: 20,
        status: :active
      })
      |> Repo.insert!()

    %{node: node, vps: vps, owner: "cost-#{System.unique_integer([:positive])}@example.com"}
  end

  defp record(ctx, metered_at, seconds) do
    %UsageRecord{}
    |> UsageRecord.changeset(%{
      vps_id: ctx.vps.id,
      node_id: ctx.node.id,
      owner_email: ctx.owner,
      metered_at: metered_at,
      seconds: seconds,
      vcpu: 2,
      ram_mb: 2048,
      disk_gb: 20
    })
    |> Repo.insert!()
  end

  # Een beheerderssessie, geen gedeeld geheim meer: zie `ConnCase.als_beheerder/1`.
  defp admin(conn), do: conn |> als_beheerder() |> elem(0)

  defp usage(conn, from, to) do
    conn
    |> admin()
    |> get(@path, %{"from" => from, "to" => to})
  end

  defp centre(body, owner), do: Enum.find(body["cost_centres"], &(&1["owner_email"] == owner))

  defp second_vps(ctx) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: ctx.vps.region_id,
      node_id: ctx.node.id,
      vcpu: 2,
      ram_mb: 2048,
      disk_gb: 20,
      status: :active
    })
    |> Repo.insert!()
  end

  test "sums the records inside the window", ctx do
    record(ctx, ~U[2026-06-01 10:00:00Z], 3600)
    record(ctx, ~U[2026-06-01 11:00:00Z], 1800)

    body =
      usage(ctx.conn, "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z")
      |> json_response(200)

    row = centre(body, ctx.owner)
    assert row["seconds"] == 5400
    assert row["records"] == 2
    # A string, not a float: a float here is how a cent goes missing.
    assert is_binary(row["amount"])
    assert {_, ""} = Decimal.parse(row["amount"])
  end

  test "the window is half-open, so adjacent windows tile", ctx do
    boundary = ~U[2026-06-02 00:00:00Z]
    record(ctx, boundary, 600)

    before = usage(ctx.conn, "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z") |> json_response(200)
    after_ = usage(ctx.conn, "2026-06-02T00:00:00Z", "2026-06-03T00:00:00Z") |> json_response(200)

    # A record exactly on the boundary belongs to the later window and to only
    # one of them — counting it twice inflates every monthly total by a tick.
    assert centre(before, ctx.owner) == nil
    assert centre(after_, ctx.owner)["seconds"] == 600
  end

  test "records outside the window are left out", ctx do
    record(ctx, ~U[2026-05-31 23:59:59Z], 100)
    record(ctx, ~U[2026-06-03 00:00:01Z], 100)

    body = usage(ctx.conn, "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z") |> json_response(200)

    assert centre(body, ctx.owner) == nil
  end

  test "an empty window is an empty list, not an error", ctx do
    body = usage(ctx.conn, "2030-01-01T00:00:00Z", "2030-01-02T00:00:00Z") |> json_response(200)

    assert body["cost_centres"] == []
    assert body["from"] =~ "2030-01-01"
  end

  test "both ends of the window are required", %{conn: conn} do
    for params <- [%{}, %{"from" => "2026-06-01T00:00:00Z"}, %{"to" => "2026-06-02T00:00:00Z"}] do
      assert conn |> admin() |> get(@path, params) |> json_response(400)
    end
  end

  test "a window that runs backwards is refused", %{conn: conn} do
    resp =
      conn
      |> admin()
      |> get(@path, %{"from" => "2026-06-02T00:00:00Z", "to" => "2026-06-01T00:00:00Z"})
      |> json_response(400)

    assert resp["error"] == "invalid_window"
  end

  test "a date that is not a date is refused", %{conn: conn} do
    resp =
      conn
      |> admin()
      |> get(@path, %{"from" => "gisteren", "to" => "2026-06-02T00:00:00Z"})
      |> json_response(400)

    assert resp["error"] == "invalid_datetime"
  end

  test "the endpoint is behind an admin session", %{conn: conn} do
    params = %{"from" => "2026-06-01T00:00:00Z", "to" => "2026-06-02T00:00:00Z"}

    assert %{status: 401} = get(conn, @path, params)

    assert %{status: 401} =
             conn
             |> put_req_header("authorization", "Bearer not-the-admin-token")
             |> get(@path, params)
  end

  test "each cost centre is separate", ctx do
    record(ctx, ~U[2026-06-01 10:00:00Z], 3600)

    # Its own VPS: usage_records is unique on (vps_id, metered_at), so one
    # machine cannot be metered twice for the same instant — which is the index
    # that stops a re-run of the meter from doubling a customer's hours.
    other = %{
      ctx
      | owner: "other-#{System.unique_integer([:positive])}@example.com",
        vps: second_vps(ctx)
    }

    record(other, ~U[2026-06-01 10:00:00Z], 7200)

    body = usage(ctx.conn, "2026-06-01T00:00:00Z", "2026-06-02T00:00:00Z") |> json_response(200)

    assert centre(body, ctx.owner)["seconds"] == 3600
    assert centre(body, other.owner)["seconds"] == 7200
  end
end
