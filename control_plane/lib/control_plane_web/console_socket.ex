defmodule ControlPlaneWeb.ConsoleSocket do
  @moduledoc """
  Raw WebSocket bridge between a browser terminal (xterm.js) and a VPS SSH
  session. Bytes flow both ways: client binary frames are keystrokes forwarded to
  the SSH channel; SSH output is pushed back as binary frames. A text frame
  `{"type":"resize","cols":..,"rows":..}` resizes the PTY. The SSH dial-out is the
  existing `Console.Session` GenServer, started here with this socket as owner.
  """
  @behaviour WebSock
  require Logger
  alias ControlPlane.Console.Session
  alias ControlPlaneWeb.WsKeepalive

  # Each live session is a GenServer holding a real SSH connection to a VPS. Cap
  # how many a single user may hold at once so a scripted client can't exhaust
  # control-plane processes/FDs or hammer operator nodes' sshd (authenticated DoS).
  # Sessions register into ControlPlane.Console.Registry under {:user, uid}; the
  # duplicate registry drops dead entries automatically, so this count is live.
  @max_sessions_per_user 5

  @impl true
  def init(state) do
    if session_limit_reached?(state.user_id) do
      Logger.warning(
        "console ws: per-user session limit reached for user #{inspect(state.user_id)}"
      )

      {:stop, :normal, state}
    else
      case Session.start_link(%{
             node_id: state.node_id,
             host: state.host,
             port: state.port,
             user: state.user,
             owner: self(),
             user_id: state.user_id,
             vps_id: state.vps_id
           }) do
        {:ok, pid} ->
          WsKeepalive.plan()
          {:ok, Map.put(state, :session, pid)}

        {:error, reason} ->
          Logger.warning("console ws: session start failed: #{inspect(reason)}")
          {:stop, :normal, state}
      end
    end
  end

  defp session_limit_reached?(nil), do: false

  defp session_limit_reached?(user_id) do
    Registry.count_match(ControlPlane.Console.Registry, {:user, user_id}, nil) >=
      @max_sessions_per_user
  end

  @impl true
  def handle_in({data, [opcode: :binary]}, %{session: s} = state) do
    Session.send_input(s, data)
    {:ok, state}
  end

  def handle_in({text, [opcode: :text]}, %{session: s} = state) do
    with {:ok, %{"type" => "resize", "cols" => c, "rows" => r}} <- Jason.decode(text),
         true <- is_integer(c) and is_integer(r) do
      Session.resize(s, c, r)
    end

    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:console_output, data}, state), do: {:push, {:binary, data}, state}
  # Say why, in the terminal, before the socket goes. Closing silently leaves the
  # customer with the frontend's generic "Verbinding verbroken" and no idea
  # whether their machine is broken, their session expired, or the platform is
  # having a bad day. The console is a byte stream a terminal renders, so a
  # sentence needs no protocol — only a frame.
  def handle_info({:console_closed, reason}, state) do
    {:push, {:binary, closing_message(reason)}, {:stop, :normal, state}}
  end

  def handle_info(:ws_ping, state) do
    WsKeepalive.plan()
    {:push, {:ping, ""}, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  # Red, and with the next step in it. Every one of these is a moment where
  # someone is looking at a black rectangle wondering what they did wrong.
  defp closing_message(reason) do
    "\r\n\e[31m" <> explain(reason) <> "\e[0m\r\n"
  end

  defp explain(:econnrefused),
    do:
      "De VPS reageert nog niet op SSH. Vlak na het aanmaken duurt dat meestal nog\r\n" <>
        "een halve minuut. Sluit dit venster en probeer het zo opnieuw."

  defp explain(:etimedout),
    do: "De VPS antwoordde niet op tijd. Draait hij nog? Probeer het anders opnieuw."

  defp explain(:no_console_key),
    do: "Deze installatie heeft geen consolesleutel. Dit is een storing bij ons, niet bij jou."

  defp explain({:host_key_mismatch, _}),
    do:
      "De SSH-sleutel van deze VPS is veranderd. Dat gebeurt na het terugzetten van\r\n" <>
        "een back-up; is dat niet zo, neem dan contact op voordat je verder gaat."

  defp explain(:relay_timeout),
    do:
      "De node reageerde niet op tijd. Hij is mogelijk net offline gegaan;\r\n" <>
        "probeer het over een minuut opnieuw."

  # The catch-all covers every way an SSH handshake can fail after the node
  # attached, and by far the most common one is a machine that is up but whose
  # sshd is not listening yet. Saying that here is not a guess dressed as a fact:
  # the second sentence covers the rest, and both are things the customer can act
  # on. A bare "de verbinding is verbroken" is neither.
  defp explain(_other),
    do:
      "De console kon geen verbinding maken met de VPS.\r\n" <>
        "Vlak na het aanmaken duurt het meestal nog een halve minuut voordat de machine\r\n" <>
        "SSH aanneemt; probeer het dan opnieuw. Blijft het gebeuren, dan staat de VPS uit\r\n" <>
        "of luistert er niets op poort 22."

  @impl true
  def terminate(_reason, _state), do: :ok
end
