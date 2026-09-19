defmodule ControlPlane.FleetHartslagTest do
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Fleet.HartslagNaarBuiten

  setup do
    oud = Application.get_env(:control_plane, :deadman_url)
    on_exit(fn -> Application.put_env(:control_plane, :deadman_url, oud) end)
    :ok
  end

  test "zonder adres gebeurt er niets en blijft het tijdstip staan" do
    Application.put_env(:control_plane, :deadman_url, nil)
    assert HartslagNaarBuiten.piep(nil) == nil
    assert HartslagNaarBuiten.piep(12_345) == 12_345
  end

  test "een lege waarde telt als niet ingesteld" do
    Application.put_env(:control_plane, :deadman_url, "   ")
    assert HartslagNaarBuiten.piep(nil) == nil
  end

  test "een onbereikbaar adres houdt de klok niet op" do
    # Poort 1 op loopback: niemand luistert, dus dit faalt meteen. Wat telt is
    # dat er een tijdstip terugkomt en er geen fout naar buiten komt -- een
    # dead-man-switch die de reconciler laat struikelen neemt metering,
    # facturatie en back-ups mee.
    Application.put_env(:control_plane, :deadman_url, "http://127.0.0.1:1/ping")
    assert is_integer(HartslagNaarBuiten.piep(nil))
  end

  test "hij meldt bij het opstarten of hij aan of uit staat" do
    Application.put_env(:control_plane, :deadman_url, nil)
    assert :ok = HartslagNaarBuiten.meld_stand()
    Application.put_env(:control_plane, :deadman_url, "https://voorbeeld.invalid/ping")
    assert :ok = HartslagNaarBuiten.meld_stand()
  end
end
