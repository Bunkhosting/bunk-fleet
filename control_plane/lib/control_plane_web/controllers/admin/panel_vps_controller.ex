defmodule ControlPlaneWeb.Admin.PanelVpsController do
  @moduledoc """
  VPS-beheer in het beheerpaneel (`/api/v1/beheer/vpses*`).

  Een overzicht van alle VPS'en over de hele fleet, met starten, stoppen en
  verwijderen. Niet aan een eigenaar gebonden: alleen de beheerdersrol telt
  (`ControlPlaneWeb.Plugs.RequireAdmin`).
  """
  use ControlPlaneWeb, :controller
  import Ecto.Query
  import ControlPlaneWeb.Admin.PanelHelpers, only: [error: 3, vps_json: 1]

  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  def vpses(conn, _params) do
    vpses =
      Repo.all(
        from v in Vps,
          where: v.status != :deleted,
          order_by: [desc: v.inserted_at],
          limit: 1000,
          preload: [:region, :node]
      )

    json(conn, %{vpses: Enum.map(vpses, &vps_json/1)})
  end

  def vps_start(conn, %{"id" => id}), do: vps_action(conn, id, &Provisioning.start_vps/1)
  def vps_stop(conn, %{"id" => id}), do: vps_action(conn, id, &Provisioning.stop_vps/1)

  def vps_delete(conn, %{"id" => id}) do
    with_valid_vps(conn, id, fn vps_id ->
      case Provisioning.delete_vps(vps_id) do
        {:ok, _} -> json(conn, %{detail: "deleting"})
        {:error, :not_found} -> error(conn, :not_found, "not_found")
        {:error, reason} -> error(conn, :unprocessable_entity, to_string(reason))
      end
    end)
  end

  defp vps_action(conn, id, fun) do
    with_valid_vps(conn, id, fn vps_id ->
      case fun.(vps_id) do
        {:ok, _} -> json(conn, %{detail: "ok"})
        {:error, :not_found} -> error(conn, :not_found, "not_found")
        {:error, reason} -> error(conn, :unprocessable_entity, to_string(inspect(reason)))
      end
    end)
  end

  defp with_valid_vps(conn, id, fun) do
    case Ecto.UUID.cast(id) do
      {:ok, vps_id} -> fun.(vps_id)
      :error -> error(conn, :not_found, "not_found")
    end
  end
end
