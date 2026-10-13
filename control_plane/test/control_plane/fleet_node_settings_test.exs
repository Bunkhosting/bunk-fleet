defmodule ControlPlane.FleetNodeSettingsTest do
  @moduledoc """
  De instellingen die de eigenaar van een node vanuit het dashboard beheert.

  Twee dingen worden hier bewaakt. Dat alleen de eigenaar ze kan wijzigen, en
  dat het naampatroon het unieke deel niet kwijt kan raken: de agent herkent aan
  de naam of hij een machine al heeft aangemaakt, en toen daar ooit alleen de
  door de klant gekozen naam in stond namen twee klanten met dezelfde naam op
  een node elkaars draaiende VM over.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp gebruiker(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp fleet_node(owner) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now(),
      owner_id: owner && owner.id
    })
    |> Repo.insert!()
  end

  defp wijzig(node, user, attrs), do: NodeAdmin.update_node_settings(node.id, user, attrs)

  describe "wie mag wijzigen" do
    test "de eigenaar wel" do
      u = gebruiker("inst1@bunk.test")
      n = fleet_node(u)

      assert {:ok, bijgewerkt} = wijzig(n, u, %{"offer_ram_mb" => 3584})
      assert bijgewerkt.offer_ram_mb == 3584
    end

    test "een ander niet, ook geen beheerder" do
      eigenaar = gebruiker("inst2@bunk.test")
      {:ok, beheerder} = Accounts.update_user_role(gebruiker("inst-adm@bunk.test"), :admin)
      n = fleet_node(eigenaar)

      assert {:error, :forbidden} = wijzig(n, beheerder, %{"offer_ram_mb" => 1})
      assert is_nil(Repo.get!(Node, n.id).offer_ram_mb)
    end

    test "een node zonder eigenaar is van niemand" do
      n = fleet_node(nil)

      assert {:error, :forbidden} = wijzig(n, gebruiker("inst3@bunk.test"), %{"offer_vcpu" => 2})
    end
  end

  describe "het naampatroon" do
    setup do
      u = gebruiker("naam-#{System.unique_integer([:positive])}@bunk.test")
      %{user: u, node: fleet_node(u)}
    end

    test "accepteert een patroon met het unieke deel erin", %{user: u, node: n} do
      for patroon <- ["{naam}-{id}", "bunk-{id}", "{klant}-{naam}-{id}", "{node}-{id}"] do
        assert {:ok, bijgewerkt} = wijzig(n, u, %{"guest_name_pattern" => patroon})
        assert bijgewerkt.guest_name_pattern == patroon
      end
    end

    test "weigert een patroon zonder {id}", %{user: u, node: n} do
      # Dit is de kritieke fout uit juli: zonder uniek deel nam de tweede klant
      # met dezelfde naam de draaiende VM van de eerste over.
      assert {:error, changeset} = wijzig(n, u, %{"guest_name_pattern" => "{naam}"})
      assert "moet {id} bevatten" <> _ = hd(errors_on(changeset).guest_name_pattern)
    end

    test "weigert een plaatshouder die niet bestaat", %{user: u, node: n} do
      # Anders komt er letterlijk "{klantnaam}" in de naam van de machine te staan.
      assert {:error, changeset} = wijzig(n, u, %{"guest_name_pattern" => "{klantnaam}-{id}"})
      assert hd(errors_on(changeset).guest_name_pattern) =~ "bestaat niet"
    end

    test "weigert tekens die geen geldige gastnaam opleveren", %{user: u, node: n} do
      for slecht <- ["Bunk_{id}", "bunk {id}", "bunk.{id}!"] do
        assert {:error, _} = wijzig(n, u, %{"guest_name_pattern" => slecht})
      end
    end

    test "leeg betekent terug naar de standaard", %{user: u, node: n} do
      {:ok, _} = wijzig(n, u, %{"guest_name_pattern" => "bunk-{id}"})

      assert {:ok, bijgewerkt} = wijzig(n, u, %{"guest_name_pattern" => ""})
      assert is_nil(bijgewerkt.guest_name_pattern)
    end
  end

  describe "het VMID-bereik" do
    setup do
      u = gebruiker("vmid-#{System.unique_integer([:positive])}@bunk.test")
      %{user: u, node: fleet_node(u)}
    end

    test "accepteert een geldig bereik", %{user: u, node: n} do
      assert {:ok, bijgewerkt} = wijzig(n, u, %{"vmid_min" => 2000, "vmid_max" => 2999})
      assert bijgewerkt.vmid_min == 2000
    end

    test "weigert een bereik dat de template bevat", %{user: u, node: n} do
      # De agent zou daar ooit aankomen en zijn eigen bron overschrijven.
      assert {:error, changeset} = wijzig(n, u, %{"vmid_min" => 8000, "vmid_max" => 9500})
      assert hd(errors_on(changeset).vmid_min) =~ "template"
    end

    test "weigert ook een bereik dat het template van een pakket bevat", %{user: u, node: n} do
      # Een pakket mag een eigen template aanwijzen. Alleen de standaard
      # controleren laat zo'n template erdoor, en dan mislukt elke bestelling
      # van dat pakket zodra de agent bij dat nummer aankomt.
      %Package{}
      |> Package.changeset(%{
        name: "Speciaal-#{System.unique_integer([:positive])}",
        cpu_cores: 1,
        ram_gb: 1,
        disk_gb: 20,
        price_monthly: Decimal.new("1.00"),
        template_id: 4500
      })
      |> Repo.insert!()

      assert {:error, changeset} = wijzig(n, u, %{"vmid_min" => 4000, "vmid_max" => 4999})
      assert hd(errors_on(changeset).vmid_min) =~ "4500"
    end

    test "weigert een omgekeerd bereik", %{user: u, node: n} do
      assert {:error, _} = wijzig(n, u, %{"vmid_min" => 3000, "vmid_max" => 2000})
    end

    test "weigert een half bereik", %{user: u, node: n} do
      # Alleen een ondergrens zonder bovengrens is geen bereik.
      assert {:error, _} = wijzig(n, u, %{"vmid_min" => 2000})
    end
  end

  describe "de overige grenzen" do
    setup do
      u = gebruiker("grens-#{System.unique_integer([:positive])}@bunk.test")
      %{user: u, node: fleet_node(u)}
    end

    test "overboeking blijft binnen redelijke grenzen", %{user: u, node: n} do
      assert {:ok, _} = wijzig(n, u, %{"vcpu_oversubscribe" => 4})
      assert {:error, _} = wijzig(n, u, %{"vcpu_oversubscribe" => 0})
      assert {:error, _} = wijzig(n, u, %{"vcpu_oversubscribe" => 100})
    end

    test "negatieve capaciteit bestaat niet", %{user: u, node: n} do
      assert {:error, _} = wijzig(n, u, %{"offer_ram_mb" => -1})
    end

    test "raakt niets aan wat van de agent of de scheduler is", %{user: u, node: n} do
      # Een eigenaar hoort de capaciteit of de status van zijn node niet te
      # kunnen zetten, ook niet door die velden mee te sturen.
      assert {:ok, bijgewerkt} =
               wijzig(n, u, %{
                 "offer_vcpu" => 2,
                 "available_ram_mb" => 999_999,
                 "status" => "draining",
                 "agent_token_hash" => "gestolen"
               })

      assert bijgewerkt.offer_vcpu == 2
      assert is_nil(bijgewerkt.available_ram_mb)
      assert bijgewerkt.status == :online
    end
  end
end
