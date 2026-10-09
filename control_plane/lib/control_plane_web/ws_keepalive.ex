defmodule ControlPlaneWeb.WsKeepalive do
  @moduledoc """
  Houdt een stille webterminal open.

  Bandit sluit een WebSocket waarop 60 seconden niets binnenkomt, en Cloudflare
  doet hetzelfde na 100 seconden. Een terminal waarin de klant niets typt en de
  VPS niets zegt -- iemand die even iets opzoekt, een `sleep`, een prompt -- viel
  daardoor na een minuut dicht. Gemeten op 2026-10-09: na 20 seconden stilte
  leefde de sessie nog, na 80 niet meer.

  De server stuurt daarom elke #{25} seconden een ping. Een browser en de agent
  (coder/websocket) antwoorden daar vanzelf op met een pong, en dat antwoord is
  het binnenkomende verkeer waar beide grenzen naar kijken. Geen eigen protocol,
  geen werk in de frontend.
  """

  @interval_ms 25_000

  @doc "Plant de volgende ping voor de socket van het aanroepende proces."
  @spec plan() :: reference()
  def plan, do: Process.send_after(self(), :ws_ping, interval_ms())

  defp interval_ms, do: Application.get_env(:control_plane, :ws_ping_interval_ms, @interval_ms)
end
