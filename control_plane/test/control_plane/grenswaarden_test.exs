defmodule ControlPlane.GrenswaardenTest do
  @moduledoc """
  Nul, negatief, precies op de grens en net eroverheen -- voor het quotum, het
  tegoed en de node-instellingen.

  Waarom dit een eigen bestand is: de bestaande tests dekken het midden van elk
  bereik ("een geldig bereik", "een onzinnig bedrag") en daarmee glijdt een
  `>=` die een `>` had moeten zijn er ongemerkt doorheen. Precies op de grens is
  de enige waarde waarmee je dat verschil ziet, en het is ook de waarde die in
  productie het duurst is: een klant die één VPS te veel krijgt, of een
  afschrijving die bij een saldo van precies nul toch doorgaat.

  Deze tests zetten met opzet géén `Application.put_env`: die lekt naar tests die
  parallel draaien. Het echte maximum (10 VPS'en per eigenaar) wordt daarom
  gewoon volgemaakt.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Accounts
  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Provisioning

  # Het maximum dat `Provisioning.max_vpses_per_owner/0` zonder configuratie
  # aanhoudt. Hier hardgecodeerd en niet uit de config gelezen: deze test gaat er
  # juist over dat de grens ligt waar hij hoort te liggen.
  @quotum 10

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Regio #{code}"}) |> Repo.insert!()
  end

  defp fleet_node(region, owner \\ nil) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: Clock.now(),
      owner_id: owner && owner.id,
      total_vcpu: 64,
      total_ram_mb: 65_536,
      total_disk_gb: 2000,
      available_vcpu: 64,
      available_ram_mb: 65_536,
      available_disk_gb: 2000
    })
    |> Repo.insert!()
  end

  defp bestel(user, region) do
    Provisioning.create_vps_for_owner(user, %{
      region_id: region.id,
      name: "v-#{System.unique_integer([:positive])}",
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      template_id: 9000
    })
  end

  describe "het quotum per eigenaar" do
    setup do
      region = regio()
      _node = fleet_node(region)
      %{region: region, user: confirmed_user_fixture()}
    end

    test "precies het maximum mag, de eerstvolgende niet", %{region: region, user: user} do
      # De grens zit in `count_live_vpses(owner) >= max`. Zou daar `>` staan, dan
      # krijgt elke klant er stil één gratis bij; zou de telling één te vroeg
      # slaan, dan kan niemand zijn laatste slot gebruiken. Alleen de tiende en
      # de elfde samen laten dat verschil zien.
      for _ <- 1..@quotum, do: assert({:ok, _} = bestel(user, region))

      assert Provisioning.count_live_vpses(user.id) == @quotum
      assert {:error, :quota_exceeded} = bestel(user, region)
      assert Provisioning.count_live_vpses(user.id) == @quotum
    end

    test "een mislukte VPS geeft het slot terug", %{region: region, user: user} do
      # `count_live_vpses/1` telt :deleted en :failed niet mee. Dat is bewust --
      # ze houden geen capaciteit meer vast -- maar het is ook precies het soort
      # regel dat bij een refactor sneuvelt, en dan zit een klant wiens uitrol
      # ooit mislukte permanent één slot lager.
      for _ <- 1..@quotum, do: assert({:ok, _} = bestel(user, region))
      assert {:error, :quota_exceeded} = bestel(user, region)

      [eerste | _] = Fleet.list_vpses_for_owner(user.id)
      eerste |> Ecto.Changeset.change(status: :failed) |> Repo.update!()

      assert Provisioning.count_live_vpses(user.id) == @quotum - 1
      assert {:ok, _} = bestel(user, region)
    end
  end

  describe "het tegoed bij bestellen" do
    test "precies genoeg is genoeg, en laat nul achter" do
      # De klassieke off-by-one in een portemonnee: `>` in plaats van `>=` maakt
      # het onmogelijk je saldo helemaal op te maken, en de klant ziet geld dat
      # hij niet kan uitgeven.
      u = confirmed_user_fixture()
      saldo = Credits.balance_cents(u.id)

      assert {:ok, %LedgerEntry{}} = Credits.charge(u.id, saldo, "vps_charge", "precies")
      assert Credits.balance_cents(u.id) == 0
    end

    test "één cent te weinig schrijft helemaal niets" do
      # Niet alleen de afwijzing telt: er mag ook geen halve boeking blijven
      # liggen. Een afgewezen afschrijving die tóch een regel achterlaat maakt
      # het grootboek onbetrouwbaar, en het grootboek is hier de enige bron van
      # het saldo.
      u = confirmed_user_fixture()
      saldo = Credits.balance_cents(u.id)
      regels = Repo.aggregate(from(e in LedgerEntry, where: e.user_id == ^u.id), :count)

      assert {:error, :insufficient_credits} =
               Credits.charge(u.id, saldo + 1, "vps_charge", "één te veel")

      assert Credits.balance_cents(u.id) == saldo
      assert Repo.aggregate(from(e in LedgerEntry, where: e.user_id == ^u.id), :count) == regels
    end

    test "een negatief bedrag afschrijven zet geen geld bij" do
      # `charge/4` vangt alles <= 0 af als een gratis no-op. Zou die clause
      # verdwijnen, dan wordt `add_entry(user, -amount)` met een negatief bedrag
      # een BIJSCHRIJVING: een klant die -100_000 meestuurt geeft zichzelf
      # duizend euro. Dat is geen theoretische zorg -- het bedrag komt uit de
      # specificatie van het gekozen pakket, en een pakket met een negatieve
      # prijs is één typefout in het beheerpaneel.
      u = confirmed_user_fixture()
      saldo = Credits.balance_cents(u.id)

      assert {:ok, nil} = Credits.charge(u.id, -100_000, "vps_charge", "negatief")
      assert Credits.balance_cents(u.id) == saldo
    end

    test "een bestelling die het saldo precies opmaakt gaat door" do
      # Dezelfde grens, maar dan via de echte bestelweg: het is de optelsom van
      # `package_price_cents/1` en `Credits.charge/4` die telt, niet de
      # afzonderlijke functie.
      u = confirmed_user_fixture()

      # Het saldo tot op de cent leegtrekken en er daarna precies de prijs van
      # één bestelling in zetten.
      staat_er_nu = Credits.balance_cents(u.id)
      {:ok, _} = Credits.charge(u.id, staat_er_nu, "vps_charge", "leeg")
      {:ok, _} = Credits.add_entry(u.id, 500, "admin_adjustment", "precies één bestelling")

      assert {:ok, _} = Credits.charge(u.id, 500, "vps_charge", "VPS")
      assert Credits.balance_cents(u.id) == 0
      assert {:error, :insufficient_credits} = Credits.charge(u.id, 1, "vps_charge", "nog een")
    end
  end

  describe "het VMID-bereik van een node" do
    setup do
      user = eigenaar()
      region = regio()
      %{user: user, node: fleet_node(region, user)}
    end

    test "precies de ondergrens mag, één eronder niet", %{user: u, node: n} do
      # 100 is het laagste VMID dat Proxmox zelf accepteert; 99 zou de agent bij
      # het aanmaken laten struikelen op een nummer dat het CP hem heeft gegeven.
      assert {:ok, _} = wijzig(n, u, %{"vmid_min" => 100, "vmid_max" => 200})
      assert {:error, _} = wijzig(n, u, %{"vmid_min" => 99, "vmid_max" => 200})
      assert Repo.get!(Node, n.id).vmid_min == 100
    end

    test "precies de bovengrens mag, één erboven niet", %{user: u, node: n} do
      assert {:ok, _} = wijzig(n, u, %{"vmid_min" => 999_999_000, "vmid_max" => 999_999_999})
      assert {:error, _} = wijzig(n, u, %{"vmid_min" => 999_999_000, "vmid_max" => 1_000_000_000})
      assert Repo.get!(Node, n.id).vmid_max == 999_999_999
    end

    test "een bereik van één nummer is een geldig bereik", %{user: u, node: n} do
      # `min > max` is de afwijzing, niet `min >= max`. Een node waar nog precies
      # één nummer vrij is hoort ingesteld te kunnen worden.
      assert {:ok, bijgewerkt} = wijzig(n, u, %{"vmid_min" => 5000, "vmid_max" => 5000})
      assert bijgewerkt.vmid_min == 5000
      assert bijgewerkt.vmid_max == 5000
    end

    test "geen bereik is ook een antwoord", %{user: u, node: n} do
      # Allebei leeg betekent "geen voorkeur" en moet blijven mogen: dat is de
      # stand waarin elke node binnenkomt.
      assert {:ok, _} = wijzig(n, u, %{"vmid_min" => 2000, "vmid_max" => 2999})
      assert {:ok, leeg} = wijzig(n, u, %{"vmid_min" => nil, "vmid_max" => nil})
      assert is_nil(leeg.vmid_min)
      assert is_nil(leeg.vmid_max)
    end
  end

  describe "de overige node-grenzen" do
    setup do
      user = eigenaar()
      region = regio()
      %{user: user, node: fleet_node(region, user)}
    end

    test "overboeking mag precies 1 en precies 32 zijn", %{user: u, node: n} do
      # 1 is "niet overboeken" en moet uitdrukkelijk kunnen; 32 is het maximum
      # dat de changeset noemt. De bestaande test probeert 0 en 100 en raakt
      # daarmee geen van beide randen.
      assert {:ok, _} = wijzig(n, u, %{"vcpu_oversubscribe" => 1})
      assert {:ok, _} = wijzig(n, u, %{"vcpu_oversubscribe" => 32})
      assert {:error, _} = wijzig(n, u, %{"vcpu_oversubscribe" => 33})
      assert Repo.get!(Node, n.id).vcpu_oversubscribe == 32
    end

    test "nul aanbieden is een geldige keuze", %{user: u, node: n} do
      # Nul is hoe een eigenaar zijn node uit de verkoop haalt zonder hem te
      # verwijderen. Zou de grens `greater_than: 0` worden, dan is de enige
      # manier om te stoppen het weghalen van de node -- met de VPS'en erop.
      assert {:ok, bijgewerkt} =
               wijzig(n, u, %{"offer_vcpu" => 0, "offer_ram_mb" => 0, "offer_disk_gb" => 0})

      assert bijgewerkt.offer_ram_mb == 0
      assert {:error, _} = wijzig(n, u, %{"offer_ram_mb" => -1})
    end
  end

  defp eigenaar do
    email = "grens-#{System.unique_integer([:positive])}@bunk.test"
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp wijzig(node, user, attrs), do: Fleet.update_node_settings(node.id, user, attrs)
end
