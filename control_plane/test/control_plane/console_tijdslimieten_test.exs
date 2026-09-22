defmodule ControlPlane.ConsoleTijdslimietenTest do
  @moduledoc """
  De drie grenzen op het consolepad moeten in de goede volgorde staan.

  Een terminal opent via drie schakels, elk met een eigen tijdslimiet:

    1. de agent probeert twaalf seconden lang de VPS te bereiken
       (`consoleDialWindow`, cmd/bunk-agent/console.go), en belt daarna terug om
       te zeggen dat het niet lukt;
    2. de relay geeft de agent vijftien seconden om te koppelen
       (`Relay.attach_timeout_ms/0`);
    3. de SSH-verbinding erdoorheen heeft zijn eigen grens
       (`Session.connect_timeout_ms/0`).

  Die van (3) hoort de grootste te zijn. Stond hij op tien seconden, en dat is
  maandenlang zo geweest: dan wint de kortste, en daarmee is de tijd uit (1) en
  (2) nooit beschikbaar. Het gevolg was zichtbaar bij klanten -- één op de zes
  sessies viel om met "je VPS neemt geen SSH aan", terwijl de VPS gewoon draaide
  en de handshake dóór de tunnel alleen net iets langer deed.

  Deze test bestaat omdat het verband niet uit de code blijkt: het zijn twee
  getallen in twee bestanden, en niets verbood ooit dat iemand de verkeerde
  kleiner maakte.
  """
  use ExUnit.Case, async: true

  alias ControlPlane.Console.Relay
  alias ControlPlane.Console.Session

  # Hardcoded, en dat is de bedoeling: dit getal staat in de Go-agent en kan
  # hier niet worden opgevraagd. Verandert het daar, dan hoort deze test rood te
  # worden zodat iemand beide kanten naast elkaar legt.
  @agent_dial_window_ms 12_000

  test "de agent krijgt minder tijd dan de relay, zodat zijn melding nog aankomt" do
    assert @agent_dial_window_ms < Relay.attach_timeout_ms(),
           "de agent geeft het pas op nadat de relay al dicht is; zijn uitleg " <>
             "bereikt de klant dan nooit"
  end

  test "de SSH-grens ligt boven de koppelgrens van de relay" do
    assert Session.connect_timeout_ms() > Relay.attach_timeout_ms(),
           "de SSH-verbinding geeft het op vóór de relay dat doet; dan is de " <>
             "tijd die de relay geeft nooit beschikbaar en krijgt de klant een " <>
             "melding over zijn VPS die nergens op slaat"
  end
end
