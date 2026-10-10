defmodule ControlPlane.CreditsHerkomstTest do
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry

  # Bij elkaar opgeteld maakt één getal handmatig toegekend testsaldo net zo echt
  # als geld dat een klant heeft overgemaakt. Deze uitsplitsing is het verschil,
  # dus hij moet kloppen op de cent en op de indeling.

  test "elke soort landt in zijn eigen bak en de som blijft het totaal" do
    u = confirmed_user_fixture("herkomst@bunk.test")
    bonus = Credits.signup_bonus_cents()

    {:ok, _} = Credits.add_entry(u.id, 2_500, "topup", "Tegoed bijgeboekt (BUNK-1)")
    {:ok, _} = Credits.add_entry(u.id, 9_999, "admin_adjustment", "Handmatig")
    {:ok, _} = Credits.add_entry(u.id, 1_000, "admin_topup", "Handmatig")
    {:ok, _} = Credits.add_entry(u.id, -400, "vps_charge", "VPS Starter")

    h = Credits.saldo_naar_herkomst()

    assert h.betaald == 2_500
    assert h.weggegeven == bonus
    assert h.handmatig == 10_999
    assert h.verbruikt == -400
    assert h.overig == 0

    totaal = h.betaald + h.weggegeven + h.handmatig + h.verbruikt + h.overig
    assert totaal == Credits.balance_cents(u.id)
  end

  test "een onbekende soort kan niet geboekt worden" do
    # Vroeger kwam die onder "overig" terecht. Sinds de CHECK-constraint op
    # ledger_entries.kind bestaat hij niet meer: een nieuwe soort moet eerst in
    # LedgerEntry.soorten (en de migratie) staan.
    u = confirmed_user_fixture("herkomst2@bunk.test")
    assert {:error, _} = Credits.add_entry(u.id, 5_000, "kortingsactie_2027", "Iets nieuws")
  end

  test "elke soort die geboekt mag worden, heeft een herkomst" do
    # Wie een soort aan de lijst toevoegt maar vergeet hem in te delen, ziet
    # dat geld onder "overig" verdwijnen. Hier valt het op.
    u = confirmed_user_fixture("herkomst3@bunk.test")
    voor = Credits.saldo_naar_herkomst().overig

    for soort <- LedgerEntry.soorten() do
      {:ok, _} = Credits.add_entry(u.id, 1, soort, "proef")
    end

    assert Credits.saldo_naar_herkomst().overig == voor
  end
end
