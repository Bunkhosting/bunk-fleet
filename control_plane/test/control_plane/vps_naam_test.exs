defmodule ControlPlane.VpsNaamTest do
  @moduledoc """
  Een VPS-naam is een naam.

  Het bestelscherm belooft "alleen letters, cijfers, koppeltekens en
  underscores", maar de API dwong dat niet af: `<script>alert(1)</script>` werd
  gewoon opgeslagen. Geen XSS-gat -- React en LiveView escapen allebei -- maar
  wel het gat tussen wat een scherm belooft en wat de API afdwingt, en een
  aanvaller gebruikt het scherm niet.

  De naam reist bovendien verder dan het dashboard: hij komt in de gastnaam op de
  hypervisor, in operationele mail en in logs, en elk van die plekken heeft zijn
  eigen manier om ergens uit te ontsnappen.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Vps

  defp naam_ok?(naam) do
    %Vps{}
    |> Vps.changeset(%{
      name: naam,
      region_id: Ecto.UUID.generate(),
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20
    })
    |> Map.get(:errors)
    |> Keyword.get(:name)
    |> is_nil()
  end

  test "gewone namen komen erdoor, ook de namen die er al zijn" do
    for naam <- [
          "Test",
          "Test-VM",
          "test-vm",
          "Test11",
          "vps-1789030904347",
          "Web server 2",
          "db-prod.eu",
          "mijn_server",
          "Zürich-1"
        ] do
      assert naam_ok?(naam), "#{naam} werd geweigerd"
    end
  end

  test "markup, aanhalingstekens en shell-tekens niet" do
    for naam <- [
          "<script>alert(1)</script>",
          "naam\"met\"quotes",
          "'; rm -rf /",
          "$(whoami)",
          "`id`",
          "naam;met;puntkomma",
          "a|b",
          "x&y",
          "{{7*7}}",
          "../../etc/passwd"
        ] do
      refute naam_ok?(naam), "#{naam} werd geaccepteerd"
    end
  end

  test "er moet minstens iets van een naam in staan" do
    refute naam_ok?(""), "lege naam werd geaccepteerd"
    refute naam_ok?("   "), "alleen spaties werd geaccepteerd"
    refute naam_ok?("---"), "alleen koppeltekens werd geaccepteerd"
    assert naam_ok?("a"), "één letter hoort te mogen"
  end
end
