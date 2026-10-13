defmodule ControlPlaneWeb.Admin.TopupController do
  @moduledoc "Admin queue for customer top-up requests; confirming one credits the wallet."
  use ControlPlaneWeb, :controller

  alias ControlPlane.Credits
  alias ControlPlane.Credits.Topups

  def index(conn, _params) do
    json(conn, %{requests: Enum.map(Topups.list_pending_topups(), &request_json/1)})
  end

  # "manual": een mens zet deze op betaald, niet de webhook van de provider.
  # Dat wordt vastgelegd omdat het bepaalt of het bedrag als omzet meetelt.
  def confirm(conn, %{"id" => id}) do
    case Topups.mark_topup_paid(id, "manual") do
      {:ok, tr} ->
        json(conn, %{
          id: tr.id,
          reference: tr.reference,
          status: tr.status,
          balance_cents: Credits.balance_cents(tr.user_id)
        })

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "topup_not_found"})

      {:error, :not_pending} ->
        conn |> put_status(:conflict) |> json(%{error: "not_pending"})
    end
  end

  defp request_json(tr) do
    %{
      id: tr.id,
      email: tr.user && tr.user.email,
      amount_cents: tr.amount_cents,
      reference: tr.reference,
      requested_at: tr.inserted_at
    }
  end
end
