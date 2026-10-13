defmodule ControlPlane.BillingRevenueTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Billing.Revenue
  alias ControlPlane.Credits
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Credits.Topups
  alias ControlPlane.Repo

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "test-only-password-4f2b9c1e"})
    u
  end

  defp paid_topup(user, cents, %Date{} = op) do
    # Met een Mollie-id, want alleen een betaling die bij de provider bestond is
    # omzet. Zie de test "handmatig toegekend tegoed telt niet mee".
    {:ok, r} =
      Topups.create_mollie_topup(user.id, cents, "tr_#{System.unique_integer([:positive])}")

    {:ok, r} = Topups.mark_topup_paid(r.id, "mollie")

    # De datum zetten we expliciet: een aangifte gaat over een periode, en een
    # test die alles op vandaag zet bewijst niets over de afbakening ervan.
    r
    |> Ecto.Changeset.change(paid_at: DateTime.new!(op, ~T[12:00:00], "Etc/UTC"))
    |> Repo.update!()
  end

  describe "btw uit een brutobedrag" do
    test "netto en btw tellen altijd op tot het brutobedrag" do
      # Als dit ooit een cent verliest, klopt de aangifte niet meer met de
      # rekening. Daarom over het hele bereik dat een topup kan hebben.
      for gross <- [500, 999, 1000, 1234, 2500, 3999, 7999, 10_000, 99_999, 100_000] do
        %{gross_cents: g, net_cents: n, vat_cents: v} = Revenue.split(gross)
        assert g == gross
        assert n + v == gross, "#{gross} valt uiteen in #{n} + #{v}"
      end
    end

    test "21% wordt uit een inclusief bedrag teruggerekend, niet erbovenop" do
      # 12,10 inclusief is 10,00 netto en 2,10 btw. Andersom rekenen zou
      # 12,10 + 2,54 opleveren en dus te veel afdragen.
      assert %{net_cents: 1000, vat_cents: 210} = Revenue.split(1210)
      assert Revenue.vat_percentage() == 21.0
    end

    test "nul blijft nul" do
      assert %{gross_cents: 0, net_cents: 0, vat_cents: 0} = Revenue.split(0)
    end
  end

  describe "totalen over een periode" do
    test "telt alleen betaalde topups, niet openstaande of geannuleerde" do
      u = user("rev1@bunk.test")
      paid_topup(u, 2500, ~D[2026-02-10])
      {:ok, _open} = Topups.create_topup_request(u.id, 5000)

      totals = Revenue.summary(~D[2026-01-01], ~D[2026-12-31])

      assert totals.payments == 1
      assert totals.gross_cents == 2500
      assert totals.net_cents + totals.vat_cents == 2500
    end

    test "de grenzen van de periode tellen volledig mee" do
      u = user("rev2@bunk.test")
      paid_topup(u, 1000, ~D[2026-04-01])
      paid_topup(u, 2000, ~D[2026-06-30])
      paid_topup(u, 4000, ~D[2026-07-01])

      kwartaal = Revenue.summary(~D[2026-04-01], ~D[2026-06-30])

      assert kwartaal.payments == 2
      assert kwartaal.gross_cents == 3000
    end

    test "weggegeven tegoed is geen omzet" do
      # Een signup_bonus is een grootboekregel zonder betaling erachter. Zou de
      # omzet aan het grootboek hangen in plaats van aan de topups, dan telde
      # die euro mee en zou er btw over afgedragen worden die niemand betaalde.
      u = user("rev3@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 1000, "signup_bonus", "welkom")

      assert %{payments: 0, gross_cents: 0, vat_cents: 0} =
               Revenue.summary(~D[2026-01-01], ~D[2026-12-31])
    end
  end

  describe "per kwartaal" do
    test "groepeert op het kwartaal waarin betaald is" do
      u = user("rev4@bunk.test")
      paid_topup(u, 1000, ~D[2026-02-15])
      paid_topup(u, 3000, ~D[2026-05-20])
      paid_topup(u, 2000, ~D[2026-05-21])

      assert [q1, q2] = Revenue.by_quarter(~D[2026-01-01], ~D[2026-12-31])

      assert q1.label == "2026 Q1"
      assert q1.payments == 1
      assert q1.gross_cents == 1000

      assert q2.label == "2026 Q2"
      assert q2.payments == 2
      assert q2.gross_cents == 5000
      assert q2.net_cents + q2.vat_cents == 5000
    end
  end

  describe "factuurregels" do
    test "één regel per betaling, met referentie en klant" do
      u = user("rev5@bunk.test")
      r = paid_topup(u, 2500, ~D[2026-03-03])

      assert [regel] = Revenue.invoices(~D[2026-03-01], ~D[2026-03-31])

      assert regel.reference == r.reference
      assert regel.customer == "rev5@bunk.test"
      assert regel.gross_cents == 2500
      assert regel.net_cents + regel.vat_cents == 2500
    end

    test "de som van de regels is gelijk aan het periodetotaal" do
      # Het overzicht en de onderliggende regels mogen nooit uit elkaar lopen:
      # dat is precies het verschil dat bij een controle wordt opgemerkt.
      u = user("rev6@bunk.test")

      for {cents, dag} <- [{999, ~D[2026-01-05]}, {2500, ~D[2026-02-05]}, {7999, ~D[2026-03-05]}] do
        paid_topup(u, cents, dag)
      end

      regels = Revenue.invoices(~D[2026-01-01], ~D[2026-03-31])
      totaal = Revenue.summary(~D[2026-01-01], ~D[2026-03-31])

      assert Enum.sum(Enum.map(regels, & &1.gross_cents)) == totaal.gross_cents
      assert Enum.sum(Enum.map(regels, & &1.vat_cents)) == totaal.vat_cents
      assert Enum.sum(Enum.map(regels, & &1.net_cents)) == totaal.net_cents

      # Deze drie bedragen (999, 2500, 7999) zijn niet willekeurig: per regel
      # afgerond geven ze 1995 cent btw, in één keer over het brutototaal 1996.
      # Zou het overzicht op die tweede manier rekenen, dan verschilt het van de
      # facturen waarop de btw daadwerkelijk in rekening is gebracht.
      assert totaal.vat_cents == 1995
    end
  end

  test "een lege periode geeft nullen terug in plaats van niets" do
    assert %{payments: 0, gross_cents: 0, net_cents: 0, vat_cents: 0} =
             Revenue.summary(~D[2020-01-01], ~D[2020-12-31])

    assert [] = Revenue.by_quarter(~D[2020-01-01], ~D[2020-12-31])
    assert [] = Revenue.invoices(~D[2020-01-01], ~D[2020-12-31])
  end

  describe "met de hand op betaald gezet" do
    test "telt niet als omzet, ook al bestond de betaling bij de provider" do
      # Dit is het geval dat eerder wél meetelde: een verzoek dat bij Mollie is
      # aangemaakt en daarna door een mens op betaald gezet. Er hoeft dan geen
      # euro binnengekomen te zijn, en btw afdragen over geld dat er niet is
      # kost echt geld.
      u = user("hand4@bunk.test")

      {:ok, r} =
        Topups.create_mollie_topup(u.id, 5000, "tr_hand_#{System.unique_integer([:positive])}")

      {:ok, _} = Topups.mark_topup_paid(r.id, "manual")

      assert %{payments: 0, gross_cents: 0} = Revenue.summary(~D[2026-01-01], ~D[2026-12-31])
      assert Revenue.invoices(~D[2026-01-01], ~D[2026-12-31]) == []
    end

    test "valt niet weg maar staat apart, met de reden erbij" do
      # Uitsluiten zonder tonen is verbergen: een bedrag dat nergens meer opduikt
      # is niet te controleren tegen de bankafschriften.
      u = user("hand5@bunk.test")

      {:ok, r} =
        Topups.create_mollie_topup(u.id, 5000, "tr_hand_#{System.unique_integer([:positive])}")

      {:ok, r} = Topups.mark_topup_paid(r.id, "manual")

      Repo.update!(
        Ecto.Changeset.change(r, paid_at: DateTime.new!(~D[2026-03-03], ~T[12:00:00], "Etc/UTC"))
      )

      assert [regel] = Revenue.excluded(~D[2026-03-01], ~D[2026-03-31])
      assert regel.amount_cents == 5000
      assert regel.customer == "hand5@bunk.test"
      assert regel.reason =~ "hand"
    end

    test "een betaling uit de testperiode telt niet mee en staat apart" do
      # Tot 14 september 2026 stond Mollie op de testsleutel. Zulke rijen zien er
      # in de database uit als echte betalingen — status, bedrag, een Mollie-id —
      # terwijl er nooit geld voor binnenkwam. Ze horen dus niet in de aangifte,
      # maar wel in het overzicht: anders is het verschil met de bankafschriften
      # niet te verklaren.
      u = user("test1@bunk.test")

      {:ok, r} =
        Topups.create_mollie_topup(u.id, 5000, "tr_test_#{System.unique_integer([:positive])}")

      {:ok, r} = Topups.mark_topup_paid(r.id, "mollie")

      Repo.update!(
        Ecto.Changeset.change(r,
          paid_via: "mollie_test",
          paid_at: DateTime.new!(~D[2026-09-13], ~T[12:00:00], "Etc/UTC")
        )
      )

      assert %{payments: 0, gross_cents: 0} = Revenue.summary(~D[2026-09-01], ~D[2026-09-30])
      assert [regel] = Revenue.excluded(~D[2026-09-01], ~D[2026-09-30])
      assert regel.amount_cents == 5000
      assert regel.reason =~ "test"
    end

    test "een bevestiger die ontbreekt telt niet mee, in plaats van mee te liften" do
      # NULL betekende hier ooit "van vóór deze kolom" en telde daarom mee. Dat
      # maakt elke toekomstige rij zonder bevestiger stilzwijgend tot omzet; de
      # veilige kant van die keuze is niet meetellen.
      u = user("test2@bunk.test")

      {:ok, r} =
        Topups.create_mollie_topup(u.id, 1500, "tr_null_#{System.unique_integer([:positive])}")

      {:ok, r} = Topups.mark_topup_paid(r.id, "mollie")

      Repo.update!(
        Ecto.Changeset.change(r,
          paid_via: nil,
          paid_at: DateTime.new!(~D[2026-09-20], ~T[12:00:00], "Etc/UTC")
        )
      )

      assert %{payments: 0, gross_cents: 0} = Revenue.summary(~D[2026-09-01], ~D[2026-09-30])
      assert [%{reason: reden}] = Revenue.excluded(~D[2026-09-01], ~D[2026-09-30])
      assert reden =~ "onbekend"
    end

    test "een betaling die de webhook bevestigde telt gewoon mee" do
      u = user("hand6@bunk.test")
      paid_topup(u, 2500, ~D[2026-04-04])

      assert %{payments: 1, gross_cents: 2500} =
               Revenue.summary(~D[2026-01-01], ~D[2026-12-31])

      assert Revenue.excluded(~D[2026-01-01], ~D[2026-12-31]) == []
    end

    test "de bron staat op de factuurregel" do
      u = user("hand7@bunk.test")
      paid_topup(u, 1000, ~D[2026-05-05])

      assert [%{paid_via: "mollie"}] = Revenue.invoices(~D[2026-05-01], ~D[2026-05-31])
    end
  end

  describe "handmatig toegekend tegoed" do
    test "een adminopwaardering in het grootboek telt niet mee" do
      # Het beheerpaneel hoogt een saldo op met een grootboekregel, zonder
      # opwaarderingsverzoek en zonder betaling. De klant kan er meer mee
      # uitgeven, maar er is geen euro binnengekomen — dus geen omzet en geen
      # btw. Dit is precies het geval waarvoor Stijn deze grens vroeg.
      u = user("hand1@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 5000, "admin_topup", "Handmatig door beheerder")
      {:ok, _} = Credits.add_entry(u.id, -1000, "admin_adjustment", "Correctie")

      assert %{payments: 0, gross_cents: 0, vat_cents: 0} =
               Revenue.summary(~D[2026-01-01], ~D[2026-12-31])

      assert Revenue.invoices(~D[2026-01-01], ~D[2026-12-31]) == []
    end

    test "een betaald verzoek zonder betaling bij de provider telt niet mee" do
      # Zou er ooit een knop komen die wél een opwaarderingsverzoek aanmaakt en
      # dat met de hand op betaald zet, dan hoort dat bedrag niet in de aangifte.
      # Zonder deze eis zou het er stilzwijgend in belanden.
      u = user("hand2@bunk.test")
      {:ok, r} = Topups.create_topup_request(u.id, 2500)
      {:ok, _} = Topups.mark_topup_paid(r.id, "mollie")

      assert %{payments: 0, gross_cents: 0} = Revenue.summary(~D[2026-01-01], ~D[2026-12-31])
    end

    test "naast handmatig tegoed telt een echte betaling gewoon door" do
      u = user("hand3@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 9999, "admin_topup", "Handmatig")
      paid_topup(u, 2500, ~D[2026-05-05])

      totaal = Revenue.summary(~D[2026-01-01], ~D[2026-12-31])
      assert totaal.payments == 1
      assert totaal.gross_cents == 2500
    end
  end

  test "de referentie is uniek, zodat hij als factuurnummer kan dienen" do
    u = user("rev7@bunk.test")
    a = paid_topup(u, 1000, ~D[2026-01-10])
    b = paid_topup(u, 1000, ~D[2026-01-11])

    assert a.reference != b.reference
    assert Repo.aggregate(TopupRequest, :count, :id) == 2
  end
end
