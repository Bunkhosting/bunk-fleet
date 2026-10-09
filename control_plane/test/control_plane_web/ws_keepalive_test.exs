defmodule ControlPlaneWeb.WsKeepaliveTest do
  @moduledoc """
  Beide kanten van een webterminal sturen pings, en blijven dat doen.

  Een stille sessie viel na een minuut dicht (Bandit) of na honderd seconden
  (Cloudflare). De echte proef is een sessie die langer stil staat dan dat --
  e2e/api/fwproef.py `stil` -- maar die heeft een draaiende VPS nodig. Dit legt
  vast dat de pings er zijn en zichzelf opnieuw plannen.
  """
  use ExUnit.Case, async: false

  alias ControlPlaneWeb.ConsoleRelaySocket
  alias ControlPlaneWeb.ConsoleSocket

  setup do
    vorige = Application.get_env(:control_plane, :ws_ping_interval_ms)
    Application.put_env(:control_plane, :ws_ping_interval_ms, 10)

    on_exit(fn ->
      if vorige,
        do: Application.put_env(:control_plane, :ws_ping_interval_ms, vorige),
        else: Application.delete_env(:control_plane, :ws_ping_interval_ms)
    end)
  end

  for module <- [ConsoleSocket, ConsoleRelaySocket] do
    test "#{inspect(module)} pingt en plant de volgende" do
      assert {:push, {:ping, ""}, %{}} = unquote(module).handle_info(:ws_ping, %{})
      assert_receive :ws_ping, 500
    end
  end
end
