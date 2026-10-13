defmodule ControlPlaneWeb.Admin.RegionController do
  @moduledoc """
  Operator/admin API for fleet regions.

  Protected by the `:admin_session_api` pipeline: an admin's own session,
  with a second factor (see `ControlPlaneWeb.Plugs.RequireAdmin`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Regions

  def index(conn, _params) do
    regions = Enum.map(Regions.list_regions(), &region_json/1)
    json(conn, %{regions: regions})
  end

  def create(conn, params) do
    # Only forward `enabled` when explicitly supplied; otherwise let the schema/DB
    # default (true) apply rather than casting a nil over it (NOT NULL column).
    attrs =
      %{code: params["code"], name: params["name"]}
      |> then(fn a ->
        case params["enabled"] do
          nil -> a
          v -> Map.put(a, :enabled, v)
        end
      end)

    case Regions.create_region(attrs) do
      {:ok, region} ->
        conn
        |> put_status(:created)
        |> json(%{region: region_json(region)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_region", details: errors(changeset)})
    end
  end

  defp region_json(%Region{} = region) do
    %{
      id: region.id,
      code: region.code,
      name: region.name,
      enabled: region.enabled
    }
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
