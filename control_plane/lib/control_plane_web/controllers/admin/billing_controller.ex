defmodule ControlPlaneWeb.Admin.BillingController do
  @moduledoc """
  Admin API for metered fleet usage: what each node cost centre's capacity
  actually served over a window. This is internal cost accounting (how much of
  our own hardware a period consumed), not customer billing — customers are
  billed via subscriptions and the prepaid wallet.

  `usage` (GET `/admin/v1/billing/usage?from=&to=`) returns the per-cost-centre
  resource summary for the half-open window `[from, to)` (records with
  `metered_at >= from and metered_at < to`, so adjacent windows tile without
  double-counting the boundary). `from`/`to` are ISO8601 datetimes (e.g.
  `2026-06-01T00:00:00Z`); both are required. `amount` is a money value in the
  unit configured via `:control_plane, :billing_rates` (see
  `ControlPlane.Billing` for the model and units), serialized as a string to
  preserve Decimal precision.

  Protected by the `:admin_session_api` pipeline: an admin's own session,
  with a second factor (see `ControlPlaneWeb.Plugs.RequireAdmin`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Billing
  alias ControlPlaneWeb.TimeWindow

  def usage(conn, params) do
    case TimeWindow.parse(params, require: true) do
      {:ok, {from, to}} ->
        summary = Enum.map(Billing.resource_cost_summary({from, to}), &cost_json/1)

        json(conn, %{
          from: DateTime.to_iso8601(from),
          to: DateTime.to_iso8601(to),
          cost_centres: summary
        })

      {:error, :invalid_datetime} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_datetime", detail: "from and to must be ISO8601 datetimes"})

      {:error, :invalid_window} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_window", detail: "from must be earlier than to"})
    end
  end

  defp cost_json(%{owner_email: owner_email, amount: amount, seconds: seconds, records: records}) do
    %{
      owner_email: owner_email,
      amount: Decimal.to_string(amount),
      seconds: seconds,
      records: records
    }
  end
end
