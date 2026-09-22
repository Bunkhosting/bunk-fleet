defmodule ControlPlaneWeb.ConsoleController do
  @moduledoc """
  Owner-scoped console access:

    * POST /api/v1/vpses/:id/console-ticket — the authenticated owner of an active
      VPS mints a single-use ticket for one WebSocket console session.
    * GET  /ws/console/:id?ticket=... — redeems the ticket (verifying it matches
      this VPS) and upgrades to `ConsoleSocket`, which SSHes into the VPS.
  """
  use ControlPlaneWeb, :controller
  import ControlPlaneWeb.ApiResponse

  alias ControlPlane.Console
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Vps
  alias ControlPlaneWeb.Fouten

  def create_ticket(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Vps{status: :active, ip_address: ip} <- Fleet.get_vps_for_owner(user.id, uuid),
         true <- is_binary(ip) and ip != "" do
      json(conn, %{ticket: Console.Tickets.mint(uuid, user.id)})
    else
      # Deze twee zijn geen foutredenen maar uitkomsten van de `with` zelf: een
      # VPS die bestaat maar niet draait, en een VPS zonder adres. Ze blijven
      # hier staan omdat ze hier iets betekenen.
      %Vps{} -> error(conn, :conflict, "vps_not_active")
      false -> error(conn, :conflict, "console_unavailable")
      anders -> Fouten.fout(conn, anders)
    end
  end

  def ws(conn, %{"id" => id} = params) do
    with {:ok, %{vps_id: vps_id, user_id: user_id}} <- Console.Tickets.redeem(params["ticket"]),
         true <- vps_id == id,
         %Vps{status: :active, ip_address: ip, node_id: node_id} = vps <-
           Fleet.get_vps_for_owner(user_id, vps_id),
         true <- is_binary(ip) and ip != "" and is_binary(node_id) do
      state = %{
        node_id: node_id,
        host: ip,
        port: 22,
        user: console_user(),
        user_id: user_id,
        vps_id: vps.id
      }

      conn
      |> WebSockAdapter.upgrade(ControlPlaneWeb.ConsoleSocket, state, timeout: 60_000)
      |> halt()
    else
      _ -> conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  @doc """
  The node half of a console: a worker agent dialling back with a relay token.

  `NodeAuth` has already established which node is calling; the token says which
  console it is for, and `Relay.attach/3` refuses one that belongs to a different
  node.
  """
  def relay_ws(conn, params) do
    node = conn.assigns.current_node
    token = params["token"]

    if is_binary(token) and token != "" do
      conn
      |> WebSockAdapter.upgrade(
        ControlPlaneWeb.ConsoleRelaySocket,
        %{token: token, node_id: node.id},
        timeout: 60_000
      )
      |> halt()
    else
      conn |> send_resp(401, "unauthorized") |> halt()
    end
  end

  defp console_user,
    do: (Application.get_env(:control_plane, :console) || [])[:ssh_user] || "ubuntu"
end
