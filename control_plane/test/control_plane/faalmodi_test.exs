defmodule ControlPlane.FaalmodiTest do
  @moduledoc """
  Wat er gebeurt als het misgaat tussen het control plane en een node.

  Het risico hier is niet dat een verzoek mislukt -- dat mag -- maar dat een
  mislukking de administratie en de werkelijkheid uit elkaar laat lopen. Twee
  soorten schade:

    * **Capaciteit die twee keer wordt teruggegeven.** Een agent levert een
      resultaat opnieuw af omdat hij het antwoord niet zag. Wordt dat twee keer
      verwerkt, dan denkt de fleet dat hij geheugen heeft dat er niet is, en
      plaatst hij een volgende klant op een node die al vol staat.
    * **Een VPS die nergens meer heen kan.** Een node valt weg terwijl hij een
      machine aan het uitrollen is. De rij blijft staan, de klant is
      afgeschreven, en niemand merkt het tenzij er iets is dat erop let.

  De tweede test in "een node die tijdens het uitrollen wegvalt" legde eerst een
  gat vast: er was geen enkele opruimer die naar :provisioning keek. Die is er nu
  (`Sweeps.fail_stuck_provisioning_vpses/1`) en de test beschrijft wat hij
  hoort te doen.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Liveness
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Provisioning.Sweeps

  @ram_mb 4096

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Regio #{code}"}) |> Repo.insert!()
  end

  defp fleet_node(region) do
    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: Clock.now(),
      total_vcpu: 32,
      total_ram_mb: 65_536,
      total_disk_gb: 1000,
      available_vcpu: 32,
      available_ram_mb: 65_536,
      available_disk_gb: 1000
    })
    |> Repo.insert!()
  end

  defp bestel(region) do
    {:ok, %{vps: vps, command: command}} =
      Provisioning.create_vps(%{
        region_id: region.id,
        name: "v-#{System.unique_integer([:positive])}",
        vcpu: 2,
        ram_mb: @ram_mb,
        disk_gb: 50,
        owner_email: "faal-#{System.unique_integer([:positive])}@bunk.test",
        template_id: 9000
      })

    %{vps: vps, command: command}
  end

  # De node zoals de heartbeat-bewaker hem ziet nadat hij een tijd niets meer
  # heeft gezegd. Geen `Application.put_env` en geen slapende test: de cutoff
  # gaat als argument mee.
  defp valt_weg(node) do
    straks = Clock.shift(60)
    {1, _} = Liveness.mark_stale_nodes_offline(straks)
    Repo.get!(Node, node.id)
  end

  describe "een node die tijdens het uitrollen wegvalt" do
    test "de node gaat offline en er wordt niets nieuws meer op geplaatst" do
      # Dit is de helft die wél goed gaat: zodra de heartbeat oud is, valt de
      # node uit de kandidatenlijst van de scheduler. Zou dat wegvallen, dan
      # blijft het control plane bestellingen aannemen voor een machine die niet
      # meer luistert en wordt elke klant afgeschreven voor niets.
      r = regio()
      node = fleet_node(r)
      _bezig = bestel(r)

      assert valt_weg(node).status == :offline
      nog_een = nieuwe_bestelling(r)
      assert {:error, :no_capacity} = Provisioning.create_vps(nog_een)
    end

    test "de VPS die al onderweg was wordt losgemaakt en terugbetaald" do
      # Een geslaagde plaatsing zet de VPS op :provisioning en hangt er een
      # commando achter. Valt de node daarna weg, dan haalt niemand dat commando
      # nog op. Zonder opruimer blijft de rij staan, blijft de reservering :held
      # (de node lijkt voller dan hij is, ook nadat hij terugkomt), blijft de
      # klant afgeschreven en staat er "bezig" in het paneel tot iemand het
      # handmatig opmerkt.
      r = regio()
      node = fleet_node(r)
      %{vps: vps} = bestel(r)

      assert Repo.get!(Vps, vps.id).status == :provisioning
      valt_weg(node)

      # Binnen de coulanceperiode gebeurt er niets: een node die kort niets zegt
      # mag geen bestelling kosten. De grens is het hele punt, dus hij wordt aan
      # beide kanten aangeraakt.
      assert Sweeps.fail_stuck_provisioning_vpses(3600) == 0
      assert Repo.get!(Vps, vps.id).status == :provisioning

      assert Sweeps.fail_stuck_provisioning_vpses(-1) == 1
      assert Repo.get!(Vps, vps.id).status == :failed
      assert Repo.get_by!(Reservation, vps_id: vps.id).status == :released

      # En de capaciteit is terug bij de node, want anders is het bed opgemaakt
      # voor een gast die nooit kwam.
      assert Repo.get!(Node, node.id).available_ram_mb == 65_536

      # Tweemaal draaien mag niets extra's doen -- de sweeper loopt elke tik.
      assert Sweeps.fail_stuck_provisioning_vpses(-1) == 0
    end

    test "een node die alleen even stil was houdt zijn bestelling" do
      # De tegenproef. Zou de sweeper op het commando alleen afgaan in plaats van
      # op de status van de node, dan sloopt hij elke uitrol die langer duurt dan
      # de coulanceperiode -- en dat is precies de trage node waar het uitrollen
      # sowieso al langer duurt.
      r = regio()
      _node = fleet_node(r)
      %{vps: vps} = bestel(r)

      assert Sweeps.fail_stuck_provisioning_vpses(-1) == 0
      assert Repo.get!(Vps, vps.id).status == :provisioning
    end

    test "een VPS die nooit voorbij :queued kwam wordt wél opgeruimd" do
      # De andere sweeper, die over rijen gaat die nooit zijn uitgestuurd. Twee
      # sweepers met bijna dezelfde naam is een uitnodiging om er één te laten
      # vervallen bij een refactor; deze test merkt dat.
      r = regio()

      blijven_liggen =
        %Vps{}
        |> Vps.changeset(%{
          name: "q-#{System.unique_integer([:positive])}",
          region_id: r.id,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :queued
        })
        |> Repo.insert!()

      assert Sweeps.fail_stuck_queued_vpses(-1) == 1
      assert Repo.get!(Vps, blijven_liggen.id).status == :failed
    end
  end

  describe "een resultaat dat twee keer binnenkomt" do
    test "de capaciteit komt maar één keer terug" do
      # Het geval: de agent meldt een mislukte uitrol, de verbinding valt weg
      # vlak voor de 204, en hij meldt het opnieuw. Zou dat twee keer verwerkt
      # worden, dan telt de node het vrijgekomen geheugen twee keer op bij zijn
      # beschikbare capaciteit -- en verkoopt hij geheugen dat niet bestaat.
      r = regio()
      node = fleet_node(r)
      vrij_vooraf = Repo.get!(Node, node.id).available_ram_mb

      %{vps: vps, command: command} = bestel(r)
      assert Repo.get!(Node, node.id).available_ram_mb == vrij_vooraf - @ram_mb

      mislukt = %{"status" => "failed", "error" => "storage vol"}
      assert {:ok, _} = Provisioning.apply_result(command, mislukt)
      assert {:ok, _} = Provisioning.apply_result(command, mislukt)

      assert Repo.get!(Node, node.id).available_ram_mb == vrij_vooraf
      assert Repo.get!(Vps, vps.id).status == :failed
      assert Repo.get_by!(Reservation, vps_id: vps.id).status == :released
    end

    test "een tweede aflevering laat de reservering van een geslaagde uitrol met rust" do
      # De geslaagde kant van hetzelfde: de reservering is :committed en moet dat
      # blijven. Zou een dubbele aflevering hem alsnog vrijgeven, dan telt de
      # node de capaciteit van een dráaiende VM bij zijn vrije ruimte op.
      r = regio()
      node = fleet_node(r)
      vrij_vooraf = Repo.get!(Node, node.id).available_ram_mb
      %{vps: vps, command: command} = bestel(r)

      klaar = %{"status" => "done", "vm_id" => "10101", "ip" => "10.10.0.10"}
      assert {:ok, _} = Provisioning.apply_result(command, klaar)
      assert {:ok, _} = Provisioning.apply_result(command, klaar)

      assert Repo.get!(Node, node.id).available_ram_mb == vrij_vooraf - @ram_mb
      assert Repo.get!(Vps, vps.id).status == :active
      assert Repo.get_by!(Reservation, vps_id: vps.id).status == :committed
    end
  end

  describe "een resultaat voor een commando dat al terminal is" do
    test "een mislukking na een geslaagde uitrol verandert niets" do
      # Dit is geen theorie: een agent die opnieuw opstart met een half
      # geschreven statusbestand kan een oud commando alsnog als mislukt melden.
      # Wint die melding, dan gaat een draaiende VPS op :failed, verliest de
      # klant zijn machine uit het paneel, en komt de capaciteit vrij terwijl de
      # VM gewoon geheugen gebruikt.
      r = regio()
      node = fleet_node(r)
      %{vps: vps, command: command} = bestel(r)

      assert {:ok, _} =
               Provisioning.apply_result(command, %{
                 "status" => "done",
                 "vm_id" => "10101",
                 "ip" => "10.10.0.10"
               })

      vrij_na_uitrol = Repo.get!(Node, node.id).available_ram_mb

      # Opnieuw ophalen, zodat het commando dat we aanbieden de terminale status
      # al draagt -- precies zoals de controller hem uit de database leest.
      terminaal = Repo.get!(Command, command.id)
      assert {:ok, _} = Provisioning.apply_result(terminaal, %{"status" => "failed"})

      assert Repo.get!(Command, command.id).status == :done
      assert Repo.get!(Vps, vps.id).status == :active
      assert Repo.get!(Node, node.id).available_ram_mb == vrij_na_uitrol
    end

    test "een geslaagde melding na een mislukking wekt de VPS niet" do
      # De omgekeerde volgorde. Deze is gevaarlijker: de reservering is al
      # vrijgegeven en de capaciteit teruggegeven, dus een VPS die alsnog op
      # :active springt draait zonder dat er ook maar iets voor gereserveerd is.
      r = regio()
      node = fleet_node(r)
      %{vps: vps, command: command} = bestel(r)

      assert {:ok, _} = Provisioning.apply_result(command, %{"status" => "failed"})
      vrij_na_mislukking = Repo.get!(Node, node.id).available_ram_mb

      terminaal = Repo.get!(Command, command.id)

      assert {:ok, _} =
               Provisioning.apply_result(terminaal, %{
                 "status" => "done",
                 "vm_id" => "10101",
                 "ip" => "10.10.0.10"
               })

      assert Repo.get!(Command, command.id).status == :failed
      assert Repo.get!(Vps, vps.id).status == :failed
      assert Repo.get!(Node, node.id).available_ram_mb == vrij_na_mislukking
    end
  end

  defp nieuwe_bestelling(region) do
    %{
      region_id: region.id,
      name: "n-#{System.unique_integer([:positive])}",
      vcpu: 2,
      ram_mb: @ram_mb,
      disk_gb: 50,
      owner_email: "faal-#{System.unique_integer([:positive])}@bunk.test",
      template_id: 9000
    }
  end
end
