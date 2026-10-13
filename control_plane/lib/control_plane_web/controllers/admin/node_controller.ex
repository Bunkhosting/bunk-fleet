defmodule ControlPlaneWeb.Admin.NodeController do
  @moduledoc """
  Operator/admin API for inspecting fleet nodes and taking them in and out of
  service.

  Protected by the `:admin_session_api` pipeline: an admin's own session,
  with a second factor (see `ControlPlaneWeb.Plugs.RequireAdmin`).
  """
  use ControlPlaneWeb, :controller

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Repo

  def index(conn, _params) do
    nodes = Enum.map(NodeAdmin.list_nodes(), &node_json/1)
    json(conn, %{nodes: nodes})
  end

  @doc """
  Closes a node to new VPSes. Existing ones keep running and keep being served.
  """
  def drain(conn, %{"id" => id}), do: transition(conn, id, &NodeAdmin.drain_node/1)

  @doc "Reopens a drained node."
  def resume(conn, %{"id" => id}), do: transition(conn, id, &NodeAdmin.resume_node/1)

  defp transition(conn, id, change) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, node} <- change.(uuid) do
      json(conn, %{node: node_json(Repo.preload(node, :region))})
    else
      :error ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, {:invalid_status, status}} ->
        conn |> put_status(:conflict) |> json(%{error: "invalid_status_#{status}"})

      {:error, _changeset} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_node"})
    end
  end

  defp node_json(%Node{} = node) do
    %{
      id: node.id,
      name: node.name,
      region: region_code(node),
      status: node.status,
      hypervisor: node.hypervisor,
      total_vcpu: node.total_vcpu,
      total_ram_mb: node.total_ram_mb,
      total_disk_gb: node.total_disk_gb,
      available_vcpu: node.available_vcpu,
      available_ram_mb: node.available_ram_mb,
      available_disk_gb: node.available_disk_gb,
      last_heartbeat_at: node.last_heartbeat_at
    }
  end

  defp region_code(%Node{region: %{code: code}}), do: code
  defp region_code(%Node{}), do: nil
end
