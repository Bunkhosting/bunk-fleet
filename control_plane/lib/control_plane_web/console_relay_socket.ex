defmodule ControlPlaneWeb.ConsoleRelaySocket do
  @moduledoc """
  The node side of a console connection: raw bytes between a worker agent and the
  `ControlPlane.Console.Relay` that is waiting for them.

  The agent dials this after seeing a `console_connect` request on its command
  poll, carrying the relay token it was given. Binary frames are the VPS's SSH
  stream in both directions; there is no protocol of our own on top, because
  anything we invented here would just be a worse TCP.

  Authorisation is the token: it is 256 random bits, valid once, expires in
  seconds, and names a relay that a specific owner already proved they may reach.
  A second socket for the same token is a replay and is refused.
  """
  @behaviour WebSock
  require Logger

  alias ControlPlane.Console.Relay
  alias ControlPlaneWeb.WsKeepalive

  @impl true
  def init(%{token: token, node_id: node_id}) do
    case Relay.attach(token, node_id, self()) do
      {:ok, pid} ->
        Process.monitor(pid)
        WsKeepalive.plan()
        {:ok, %{relay: pid}}

      :error ->
        # Unknown, already-used or expired. Nothing to say that would not also
        # tell a prober which of those it was.
        {:stop, :normal, %{relay: nil}}
    end
  end

  @impl true
  def handle_in({data, opcode: :binary}, state) do
    Relay.from_agent(state.relay, data)
    {:ok, state}
  end

  # The agent has no reason to send text, and a text frame here is more likely a
  # confused proxy than a message worth parsing.
  def handle_in({_data, opcode: _other}, state), do: {:ok, state}

  @impl true
  def handle_info({:relay_out, data}, state), do: {:push, {:binary, data}, state}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  # Zie WsKeepalive: zonder dit sloot een stille sessie na een minuut, ook aan
  # deze kant.
  def handle_info(:ws_ping, state) do
    WsKeepalive.plan()
    {:push, {:ping, ""}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{relay: pid} = state) when is_pid(pid) do
    Relay.agent_closed(pid)
    {:ok, state}
  end

  def terminate(_reason, state), do: {:ok, state}
end
