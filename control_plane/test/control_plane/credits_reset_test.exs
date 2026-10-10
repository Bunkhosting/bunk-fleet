defmodule ControlPlane.CreditsResetTest do
  @moduledoc """
  De reset raakt geld, dus de twee dingen die eraan misgaan moeten vastliggen:
  hij moet precies op nul uitkomen, en hij mag de geschiedenis niet uitwissen.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Credits.Reset
  alias ControlPlane.Repo

  defp user(email) do
    {:ok, u} =
      ControlPlane.Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})

    u
  end

  defp regels(user_id), do: Repo.all(from(l in LedgerEntry, where: l.user_id == ^user_id))

  describe "plan" do
    test "noemt alleen saldi die niet nul zijn" do
      leeg = user("reset-leeg@bunk.test")
      vol = user("reset-vol@bunk.test")

      # Eerst neutraliseren we de aanmeldbonus, zodat deze gebruiker echt op nul
      # staat; anders bewijst de test alleen dat de bonus bestaat.
      {:ok, _} = Credits.add_entry(leeg.id, -Credits.balance_cents(leeg.id), "correction", "test")
      {:ok, _} = Credits.add_entry(vol.id, 250_000, "admin_adjustment", "test")

      emails = Enum.map(Reset.plan(), & &1.email)
      assert "reset-vol@bunk.test" in emails
      refute "reset-leeg@bunk.test" in emails
    end

    test "rekent het saldo uit het grootboek en niet uit een kolom" do
      u = user("reset-som@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 10_000, "admin_adjustment", "test")
      {:ok, _} = Credits.add_entry(u.id, -2_500, "vps_charge", "test")

      verwacht = Credits.balance_cents(u.id)
      assert %{saldo: ^verwacht} = Enum.find(Reset.plan(), &(&1.email == "reset-som@bunk.test"))
    end
  end

  describe "apply!" do
    test "brengt elk saldo op precies nul" do
      a = user("reset-a@bunk.test")
      b = user("reset-b@bunk.test")
      {:ok, _} = Credits.add_entry(a.id, 999_900, "admin_adjustment", "test")
      {:ok, _} = Credits.add_entry(b.id, 4_237, "topup", "test")

      Reset.apply!()

      assert Credits.balance_cents(a.id) == 0
      assert Credits.balance_cents(b.id) == 0
    end

    test "werkt ook als het saldo negatief is" do
      # Een gebruiker kan onder nul staan doordat een afschrijving doorging na een
      # mislukte opwaardering. Terugzetten betekent dan bijboeken, niet afboeken.
      u = user("reset-min@bunk.test")

      {:ok, _} =
        Credits.add_entry(u.id, -Credits.balance_cents(u.id) - 5_000, "vps_charge", "test")

      assert Credits.balance_cents(u.id) < 0

      Reset.apply!()
      assert Credits.balance_cents(u.id) == 0
    end

    test "haalt geen enkele bestaande regel weg" do
      # Dit is de eigenschap waar het om draait. Een saldo dat op nul komt doordat
      # de oude regels verdwenen zijn is niet te controleren tegen wat er ooit is
      # gebeurd, en dat is precies wat een grootboek moet kunnen.
      u = user("reset-hist@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 50_000, "admin_adjustment", "test")
      voor = regels(u.id) |> Enum.map(& &1.id) |> MapSet.new()

      Reset.apply!()

      na = regels(u.id) |> Enum.map(& &1.id) |> MapSet.new()
      assert MapSet.subset?(voor, na)
      assert MapSet.size(na) == MapSet.size(voor) + 1
    end

    test "is herhaalbaar zonder schade" do
      u = user("reset-twee@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 12_345, "admin_adjustment", "test")

      Reset.apply!()
      aantal = length(regels(u.id))

      # De tweede keer valt er niets meer weg te boeken, dus er hoort ook geen
      # regel bij te komen. Anders groeit het grootboek elke keer dat iemand de
      # taak per ongeluk nog eens draait.
      Reset.apply!()

      assert Credits.balance_cents(u.id) == 0
      assert length(regels(u.id)) == aantal
    end
  end

  describe "met echt geld in het systeem" do
    # Sinds de live-sleutel staat er betaald tegoed op de saldi. Deze taak
    # wiste dat zonder te vragen.
    test "weigert zolang er een echte Mollie-betaling is bijgeschreven" do
      u = user("echt-#{System.unique_integer([:positive])}@example.com")
      id = "tr_#{System.unique_integer([:positive])}"
      {:ok, tr} = Credits.create_mollie_topup(u.id, 2500, id)
      {:ok, _} = Credits.mark_topup_paid(tr.id, "mollie")
      voor = Credits.balance_cents(u.id)

      assert_raise ArgumentError, ~r/echte Mollie-betalingen/, fn -> Reset.apply!() end
      assert Credits.balance_cents(u.id) == voor

      assert [_ | _] = Reset.apply!(ook_echte_betalingen: true)
      assert Credits.balance_cents(u.id) == 0
    end
  end
end
