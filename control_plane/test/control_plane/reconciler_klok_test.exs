defmodule ControlPlane.ReconcilerKlokTest do
  @moduledoc """
  De reconciler is een klok, en die moet blijven lopen.

  Aan één tik hangt alles wat vanzelf hoort te gebeuren: nodes offline zetten,
  metering, facturatie, back-ups, vastgelopen VPS'en opruimen. `schedule_tick/1`
  stuurt het volgende bericht naar het proces zélf, dus een crash gooit dat
  bericht mee weg. Bij een fout die elke tik terugkomt levert dat een stille lus
  op in plaats van werk -- en niets in het systeem zegt dat.

  Dat was geen theorie: `roll_out_agent/0` was de enige stap zonder `rescue` en
  stond vlak vóór `schedule_tick/1`.

  De fout wordt hier in de STAAT gestopt in plaats van in de omgeving: een
  `last_meter_ms` die geen getal is laat de rekensom in `maybe_meter_usage/1`
  klappen. Dat is een echte uitzondering uit een echte stap, zonder globale
  configuratie te verzetten -- dat laatste lekt naar tests die er parallel naast
  draaien.
  """
  use ControlPlane.DataCase, async: true

  import ExUnit.CaptureLog

  alias ControlPlane.Fleet.Reconciler

  defp staat(overrides \\ %{}) do
    Map.merge(
      %{
        interval_ms: 30,
        meter_interval_ms: 3_600_000,
        last_meter_ms: nil,
        backup_check_interval_ms: 60_000,
        last_backup_check_ms: nil,
        # De mollie-stap staat er bewust in en niet weggelaten: zonder deze
        # sleutels valt hij door naar de clausule die de staat ongemoeid
        # teruggeeft, en dan loopt de gewone tik hieronder er stilzwijgend
        # omheen. Op een lege database vindt hij niets en gaat er dus ook geen
        # verzoek naar Mollie.
        mollie_interval_ms: 900_000,
        last_mollie_ms: nil
      },
      overrides
    )
  end

  test "een tik die halverwege klapt zet toch de volgende" do
    kapot = staat(%{last_meter_ms: :geen_getal})

    log =
      capture_log(fn ->
        assert {:noreply, _} = Reconciler.handle_info(:reconcile, kapot)
      end)

    # De klok loopt door: het volgende bericht staat klaar voor dit proces.
    assert_receive :reconcile, 500

    # En de fout is niet stil weggeslikt.
    assert log =~ "fleet reconciler tick faalde"
  end

  test "de staat blijft bruikbaar na een mislukte tik" do
    # Zou de tik een kapotte staat teruggeven, dan klapt elke volgende tik ook
    # en is het vangnet alleen uitstel.
    kapot = staat(%{last_meter_ms: :geen_getal})

    capture_log(fn ->
      assert {:noreply, terug} = Reconciler.handle_info(:reconcile, kapot)
      assert is_map(terug)
      assert terug.interval_ms == 30
    end)
  end

  test "een gewone tik doet zijn werk en plant de volgende" do
    log =
      capture_log(fn -> assert {:noreply, _} = Reconciler.handle_info(:reconcile, staat()) end)

    assert_receive :reconcile, 500
    refute log =~ "faalde"
  end
end
