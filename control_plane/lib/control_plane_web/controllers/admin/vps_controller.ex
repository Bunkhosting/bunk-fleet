defmodule ControlPlaneWeb.Admin.VpsController do
  @moduledoc """
  Operator/admin API for listing and provisioning VPSes.

  `create` drives `ControlPlane.Provisioning.create_vps/1`, accepting either a
  `region_id` or a `region_code`, and defaulting `template_id` from
  `Application.get_env(:control_plane, :default_template_id, 9000)`.

  Protected by the `:admin_session_api` pipeline: an admin's own session,
  with a second factor (see `ControlPlaneWeb.Plugs.RequireAdmin`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  def index(conn, _params) do
    vpses = Enum.map(Fleet.list_vpses(), &vps_json/1)
    json(conn, %{vpses: vpses})
  end

  def create(conn, params) do
    with {:ok, region_id} <- resolve_region_id(params),
         {:ok, %{vps: vps}} <- Provisioning.create_vps(build_attrs(params, region_id)) do
      conn
      |> put_status(:created)
      |> json(%{vps: vps_json(vps)})
    else
      {:error, :region_not_found} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "region_not_found"})

      {:error, :no_capacity} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "no_capacity"})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_vps"})
    end
  end

  def delete(conn, %{"id" => id}) do
    # Validate the id shape first: delete_vps/1 → Repo.get(Vps, id) raises
    # Ecto.Query.CastError (→ 500) on a non-UUID. A bad id collapses to 404.
    case Ecto.UUID.cast(id) do
      :error ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:ok, id} ->
        do_delete(conn, id)
    end
  end

  defp do_delete(conn, id) do
    case Provisioning.delete_vps(id) do
      {:ok, %{vps: vps}} ->
        conn
        |> put_status(:accepted)
        |> json(%{vps: vps_json(vps)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found"})

      {:error, :no_node} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "no_node"})

      # Elke andere weigering (al bezig met verwijderen, toestand veranderd
      # onder het slot, ...) via dezelfde vertaling als de klant-API. Zonder
      # deze tak gaf :already_deleting hier een CaseClauseError en dus een 500.
      anders ->
        ControlPlaneWeb.Fouten.fout(conn, anders)
    end
  end

  defp build_attrs(params, region_id) do
    %{
      region_id: region_id,
      name: params["name"],
      vcpu: params["vcpu"],
      ram_mb: params["ram_mb"],
      disk_gb: params["disk_gb"],
      owner_email: params["owner_email"],
      template_id: params["template_id"] || default_template_id(),
      ssh_keys: params["ssh_keys"] || [],
      cloud_init: params["cloud_init"] || %{},
      ip_config: params["ip_config"]
    }
  end

  # Accepts either `region_id` (binary_id) or `region_code` (e.g. "nl-1").
  defp resolve_region_id(%{"region_id" => region_id}) when is_binary(region_id) do
    {:ok, region_id}
  end

  defp resolve_region_id(%{"region_code" => region_code}) when is_binary(region_code) do
    case Fleet.region_by_code(region_code) do
      %Region{id: id} -> {:ok, id}
      nil -> {:error, :region_not_found}
    end
  end

  defp resolve_region_id(_params), do: {:error, :region_not_found}

  defp default_template_id do
    Application.get_env(:control_plane, :default_template_id, 9000)
  end

  # Aanmaken en verwijderen geven de struct door die `Provisioning` uit zijn
  # transactie teruggaf, zonder regio erin. Dat gaf hier `"region": null` voor
  # een VPS die wel degelijk in een regio stond. Daarom laadt de serializer zelf;
  # `Repo.preload/2` slaat over wat al geladen is, dus `index` betaalt niets extra.
  defp vps_json(%Vps{} = vps) do
    vps = Repo.preload(vps, :region)

    %{
      id: vps.id,
      name: vps.name,
      status: vps.status,
      region: region_code(vps),
      node_id: vps.node_id,
      provider_vm_id: vps.provider_vm_id,
      ip_address: vps.ip_address,
      vcpu: vps.vcpu,
      ram_mb: vps.ram_mb,
      disk_gb: vps.disk_gb,
      owner_email: vps.owner_email
    }
  end

  # Geen vangnet voor een niet-geladen regio: dat werd vroeger stil `nil` en was
  # dan niet te onderscheiden van een VPS zonder regio. `vps_json/1` laadt hem
  # altijd, dus een crash hier wijst op een pad dat dat omzeilt.
  defp region_code(%Vps{region: %Region{code: code}}), do: code
  defp region_code(%Vps{region: nil}), do: nil
end
