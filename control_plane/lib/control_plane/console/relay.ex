defmodule ControlPlane.Console.Relay do
  @moduledoc """
  Carries console bytes to a VPS the control plane cannot dial.

  The console SSHes to `vpses.ip_address`. That only works while the control
  plane and the customer network meet at one router, which is true of the first
  node and of nothing else: a node in another building keeps its VPSes on a
  private subnet behind its own NAT, and the control plane has neither a route to
  it nor a public address to be dialled back on.

  So the connection is made the other way round, over the path the agent already
  holds open:

      console  ──▶  Relay ──▶ (queued request)
                              agent polls /v1/commands, sees console_connect
      console  ◀──  Relay ◀── agent dials WSS /v1/console-relay?token=…
                              agent opens TCP to the VPS's SSH port
      bytes flow: ssh ⇄ loopback pair ⇄ Relay ⇄ WebSocket ⇄ agent ⇄ VPS

  Every console goes this way, including on nodes the control plane *could*
  reach. One path is testable; two paths diverge and the rarely-used one is the
  one that breaks.

  ## Why a loopback listener

  There is no way to hand `:ssh` an arbitrary byte stream — it wants a host and a
  port. So the relay becomes one: it listens on `127.0.0.1` on an ephemeral port,
  `Console.Session` dials that, and the accepted connection is pumped against the
  agent's WebSocket.

  (`:ssh.connect/3` also accepts an already-connected socket, which would be
  tidier. It does not work: on OTP 27 the negotiation simply times out, whether
  the socket points at a relay or straight at a VPS. The host/port path is the one
  that runs.)

  The listener takes exactly one connection and then closes, and it is bound to
  loopback, so the only thing that could race onto it is code already running
  inside the control plane — which already holds the console private key and has
  nothing to gain.
  """
  use GenServer
  require Logger

  alias ControlPlane.Console.Tickets

  @registry ControlPlane.Console.Relay.Registry
  # How long the agent has to dial back before the console gives up. The agent
  # polls every couple of seconds; anything beyond this is a node that is not
  # coming.
  #
  # De agent geeft het zelf na twaalf seconden op met de VPS
  # (`consoleDialWindow` in cmd/bunk-agent/console.go) en belt dan terug om te
  # zeggen dát hij er niet bij kan. Deze grens ligt daar bewust boven, zodat dat
  # bericht nog binnenkomt en de klant hoort wat er aan de hand is in plaats van
  # een time-out te zien.
  @attach_timeout_ms 15_000

  @doc """
  Hoelang de agent heeft om terug te bellen.

  Staat hier als functie en niet alleen als getal in dit bestand, omdat
  `ControlPlane.Console.Session` er zijn eigen grens op moet afstemmen -- en
  omdat een test dat verband kan vastleggen. Toen die twee los van elkaar
  stonden, was de SSH-grens eronder korter dan deze, en dan is de tijd die hier
  staat nooit beschikbaar.
  """
  @spec attach_timeout_ms() :: pos_integer()
  def attach_timeout_ms, do: @attach_timeout_ms

  # --- requests waiting to be polled ----------------------------------------

  @doc """
  Opens a relay for `vps_id` on `node_id`, returning `{:ok, local_port, pid}`.

  Connect to `127.0.0.1:local_port` and you are talking to the VPS. The caller is
  linked to the relay, so a browser that goes away tears the whole chain down.
  """
  def open(node_id, vps_id, host, port \\ 22) do
    token = Tickets.random_token()

    with {:ok, pid} <- start_relay(token, node_id, vps_id, host, port),
         {:ok, local_port} <- GenServer.call(pid, :local_port, 10_000) do
      {:ok, local_port, pid}
    end
  end

  @doc """
  The console requests queued for `node_id`, as agent-facing command maps.

  Drains the queue: a request is handed out once. The agent that fails to dial
  back leaves the console to time out rather than being retried, because by then
  the person has already clicked again.
  """
  def take_for_node(node_id) do
    @registry
    |> Registry.select([
      {{:"$1", :"$2", :"$3"}, [{:==, {:map_get, :node_id, :"$3"}, node_id}], [:"$3"]}
    ])
    |> Enum.flat_map(fn %{pid: pid} ->
      try do
        case GenServer.call(pid, :take_request, 1_000) do
          {:ok, request} -> [request]
          :already_taken -> []
        end
      catch
        # A relay that died between the lookup and the call is simply not
        # offering work; it must not take the whole poll down with it.
        :exit, _ -> []
      end
    end)
  end

  @doc """
  Attaches an agent's WebSocket to the relay holding `token`.

  `node_id` is the node the agent authenticated as. A relay belongs to exactly one
  node, so a token that leaked to a *different* operator's agent buys nothing —
  which matters in a fleet where the nodes are not all ours.

  Returns `{:ok, pid}`, or `:error` when the token is unknown, expired, already
  attached, or belongs to another node. All of those are one answer to the caller:
  do not talk to it.
  """
  def attach(token, node_id, ws_pid) when is_binary(token) and is_pid(ws_pid) do
    case Registry.lookup(@registry, token) do
      [{pid, %{node_id: ^node_id}}] -> GenServer.call(pid, {:attach, ws_pid}, 5_000)
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  @doc "Bytes arriving from the agent, headed for the SSH client."
  def from_agent(pid, data) when is_binary(data), do: GenServer.cast(pid, {:from_agent, data})

  @doc "The agent's side went away; close the console with it."
  def agent_closed(pid), do: GenServer.cast(pid, :agent_closed)

  # --- server ---------------------------------------------------------------

  defp start_relay(token, node_id, vps_id, host, port) do
    DynamicSupervisor.start_child(
      ControlPlane.Console.RelaySupervisor,
      {__MODULE__,
       %{
         token: token,
         node_id: node_id,
         vps_id: vps_id,
         host: host,
         port: port,
         owner: self()
       }}
    )
  end

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init(%{token: token, node_id: node_id, vps_id: vps_id, host: host, port: port, owner: owner}) do
    Process.flag(:trap_exit, true)
    Process.link(owner)

    {:ok, _} = Registry.register(@registry, token, %{pid: self(), node_id: node_id})

    {:ok,
     %{
       token: token,
       node_id: node_id,
       vps_id: vps_id,
       host: host,
       port: port,
       request_taken: false,
       ws: nil,
       sock: nil,
       listener: nil,
       acceptor: nil
     }, {:continue, :arm}}
  end

  @impl true
  def handle_continue(:arm, state) do
    listen_opts = [:binary, ip: {127, 0, 0, 1}, active: false, packet: :raw, backlog: 1]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listener} ->
        acceptor = accept_one(listener)
        # If the agent never dials back, stop rather than leaving a process and a
        # listening socket behind.
        Process.send_after(self(), :attach_timeout, @attach_timeout_ms)
        {:noreply, %{state | listener: listener, acceptor: acceptor}}

      {:error, reason} ->
        Logger.error("console relay: cannot open a loopback listener: #{inspect(reason)}")
        {:stop, :normal, state}
    end
  end

  # One connection, handed over, and then the door is shut. In a task rather than
  # the relay itself, because accept/2 blocks and the relay has to stay responsive
  # to the agent attaching in the meantime.
  defp accept_one(listener) do
    relay = self()

    spawn_link(fn ->
      case :gen_tcp.accept(listener, @attach_timeout_ms) do
        {:ok, socket} ->
          hand_over(socket, relay)

        {:error, reason} ->
          send(relay, {:accept_failed, reason})
      end
    end)
  end

  # The relay can be gone by the time a connection lands on the listener — its
  # attach timeout is running the whole time accept/2 blocks. controlling_process
  # then answers {:error, :badarg}, and matching that against :ok would crash this
  # task, which is spawn_linked: a relay that was merely late would be taken down
  # by its own acceptor. Close the socket instead of leaking it, and report.
  defp hand_over(socket, relay) do
    case :gen_tcp.controlling_process(socket, relay) do
      :ok ->
        send(relay, {:accepted, socket})

      {:error, reason} ->
        :gen_tcp.close(socket)
        send(relay, {:accept_failed, reason})
    end
  end

  @impl true
  def handle_call(:local_port, _from, %{listener: listener} = state) when not is_nil(listener) do
    {:reply, :inet.port(listener), state}
  end

  def handle_call(:local_port, _from, state) do
    {:stop, :normal, {:error, :relay_unavailable}, state}
  end

  def handle_call(:take_request, _from, %{request_taken: true} = state) do
    {:reply, :already_taken, state}
  end

  def handle_call(:take_request, _from, state) do
    request = %{
      "id" => state.token,
      "kind" => "console_connect",
      "payload" => %{
        "token" => state.token,
        "vps_id" => state.vps_id,
        "host" => state.host,
        "port" => state.port
      }
    }

    {:reply, {:ok, request}, %{state | request_taken: true}}
  end

  def handle_call({:attach, ws_pid}, _from, %{ws: nil} = state) do
    Process.monitor(ws_pid)
    # SSH may already have written its version banner while we were waiting.
    for data <- Enum.reverse(Map.get(state, :pending_out, [])),
        do: send(ws_pid, {:relay_out, data})

    {:reply, {:ok, self()}, %{state | ws: ws_pid} |> Map.put(:pending_out, [])}
  end

  # Already attached: a second socket for the same token is a replay, not a retry.
  def handle_call({:attach, _ws_pid}, _from, state), do: {:reply, :error, state}

  @impl true
  def handle_cast({:from_agent, data}, %{sock: sock} = state) when not is_nil(sock) do
    case :gen_tcp.send(sock, data) do
      :ok -> {:noreply, state}
      {:error, _closed} -> {:stop, :normal, state}
    end
  end

  # The VPS's banner can arrive before SSH has finished connecting to us. Holding
  # it costs one message; dropping it corrupts the handshake.
  def handle_cast({:from_agent, data}, state) do
    {:noreply, Map.update(state, :pending_in, [data], &[data | &1])}
  end

  def handle_cast(:agent_closed, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:tcp, _sock, data}, %{ws: ws} = state) when is_pid(ws) do
    send(ws, {:relay_out, data})
    {:noreply, state}
  end

  # SSH started talking before the agent attached. Dropping the bytes would
  # corrupt the handshake, so hold them until the WebSocket arrives.
  def handle_info({:tcp, _sock, data}, state) do
    {:noreply, Map.update(state, :pending_out, [data], &[data | &1])}
  end

  def handle_info({:accepted, socket}, state) do
    :ok = :inet.setopts(socket, active: true)
    # The listener has served its purpose; a second connection would be a
    # different conversation on the same wire.
    :gen_tcp.close(state.listener)

    for data <- Enum.reverse(Map.get(state, :pending_in, [])), do: :gen_tcp.send(socket, data)

    {:noreply, %{state | sock: socket, listener: nil} |> Map.put(:pending_in, [])}
  end

  def handle_info({:accept_failed, reason}, state) do
    Logger.info("console relay: nothing connected to the local port (#{inspect(reason)})")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_closed, _sock}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _sock, _reason}, state), do: {:stop, :normal, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}

  # The acceptor finishing is the normal course of events, not a reason to close
  # the console it just connected.
  def handle_info({:EXIT, pid, _reason}, %{acceptor: pid} = state), do: {:noreply, state}

  # Anything else linked to us is the console's owner going away.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:stop, :normal, state}

  def handle_info(:attach_timeout, %{ws: nil} = state) do
    Logger.info("console relay: node #{state.node_id} did not dial back in time")
    {:stop, :normal, state}
  end

  def handle_info(:attach_timeout, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.sock, do: :gen_tcp.close(state.sock)
    if state.listener, do: :gen_tcp.close(state.listener)
    :ok
  end
end
