defmodule ControlPlane.BestellingVerwijderdRaceTest do
  @moduledoc """
  De race tussen een bestelling en een klant die de VPS verwijdert terwijl hij
  nog `:queued` is.

  `place_and_dispatch` zette de net ingevoegde struct op `:provisioning` met een
  gewone update. Was de VPS intussen verwijderd, dan overschreef die update het
  `:deleted`, ging er een uitrol uit en draaide er een VM waarvan het abonnement
  al was opgezegd. `mark_vps_failed` en `fail_and_release_reservation` konden een
  verwijderde VPS op dezelfde manier terughalen, als `:failed`.

  Een echte race is in een test niet te regelen. Hier wordt hij nagebootst door
  de VPS in te voegen, hem te verwijderen zoals de klant dat doet, en daarna het
  bestelpad aan te roepen met de struct van vóór het verwijderen.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.PortForward
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Reservation
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Provisioning.Teardown

  setup do
    user = confirmed_user_fixture()
    region = regio()

    # Met een publiek adres, zodat een gewone bestelling een SSH-forward krijgt:
    # anders bewijst "geen forward over" na de race niets.
    fleet_node =
      %Node{}
      |> Node.changeset(%{
        name: "n-#{System.unique_integer([:positive])}",
        region_id: region.id,
        public_host: "node.example.test"
      })
      |> Ecto.Changeset.change(%{
        status: :online,
        last_heartbeat_at: ControlPlane.Clock.now(),
        total_vcpu: 32,
        total_ram_mb: 65_536,
        total_disk_gb: 1000,
        available_vcpu: 32,
        available_ram_mb: 65_536,
        available_disk_gb: 1000
      })
      |> Repo.insert!()

    {:ok, _} = Credits.add_entry(user.id, 10_000, "admin_adjustment", "startsaldo")

    %{user: user, region: region, fleet_node: fleet_node}
  end

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp bestelling(ctx, region \\ nil) do
    %{
      region_id: (region || ctx.region).id,
      name: "web-#{System.unique_integer([:positive])}",
      vcpu: 2,
      ram_mb: 2048,
      disk_gb: 20,
      owner_id: ctx.user.id,
      owner_email: ctx.user.email,
      template_id: 9000
    }
  end

  # Wat create_vps_for_owner/3 vóór het plaatsen committeert: de VPS op
  # :queued, met de afschrijving eraan.
  defp wachtende_vps(attrs) do
    vps =
      %Vps{}
      |> Vps.changeset(Map.put(attrs, :status, :queued))
      |> Repo.insert!()

    {:ok, _} = Credits.add_entry(vps.owner_id, -1234, "vps_charge", "Eerste maand", vps.id)
    vps
  end

  defp status(vps_id), do: Repo.get!(Vps, vps_id).status

  defp commandos(vps_id), do: Repo.all(from c in Command, where: c.vps_id == ^vps_id)

  defp forwards(vps_id), do: Repo.all(from f in PortForward, where: f.vps_id == ^vps_id)

  defp reserveringen(vps_id), do: Repo.all(from r in Reservation, where: r.vps_id == ^vps_id)

  defp grootboekregels(user),
    do: Repo.aggregate(from(e in LedgerEntry, where: e.user_id == ^user.id), :count)

  defp vrij_geheugen(fleet_node), do: Repo.get!(Node, fleet_node.id).available_ram_mb

  # Een VPS die verwijderd is en wiens reservering al is vrijgegeven, zoals
  # cancel_and_release dat achterlaat.
  defp verwijderd_met_vrijgegeven_reservering(ctx) do
    vps = wachtende_vps(bestelling(ctx))

    rij = from(v in Vps, where: v.id == ^vps.id)
    Repo.update_all(rij, set: [status: :deleted, node_id: ctx.fleet_node.id])

    %Reservation{}
    |> Reservation.changeset(%{
      node_id: ctx.fleet_node.id,
      vps_id: vps.id,
      vcpu: 2,
      ram_mb: 2048,
      disk_gb: 20,
      status: :released
    })
    |> Repo.insert!()

    vps
  end

  describe "plaats_en_verstuur/2 na een verwijdering" do
    test "een verwijderde VPS blijft weg: geen uitrol, geen IP, reservering vrij", ctx do
      attrs = bestelling(ctx)
      verouderd = wachtende_vps(attrs)
      geheugen = vrij_geheugen(ctx.fleet_node)
      regels = grootboekregels(ctx.user)

      # De klant verwijdert de VPS die hij in zijn lijst ziet. Zonder node gaat
      # dat via mark_vps_deleted: direct :deleted, niets vrij te geven.
      assert {:ok, %{vps: %Vps{status: :deleted}}} = Teardown.delete_vps(verouderd.id)

      # Het pad moet echt gehaald zijn: de struct waarmee besteld wordt, is nog
      # de :queued van vóór het verwijderen.
      assert %Vps{status: :queued, node_id: nil} = verouderd

      assert {:error, :already_deleting} = Provisioning.plaats_en_verstuur(verouderd, attrs)

      vps = Repo.get!(Vps, verouderd.id)
      assert vps.status == :deleted
      assert is_nil(vps.node_id)
      assert is_nil(vps.ip_address)
      assert commandos(vps.id) == []
      assert forwards(vps.id) == []

      # De scheduler hield capaciteit vast (dat bewijst dat er geplaatst is);
      # die is weer vrij, en de node heeft zijn geheugen terug.
      assert [%Reservation{status: :released}] = reserveringen(vps.id)
      assert vrij_geheugen(ctx.fleet_node) == geheugen

      # Het bestelpad zelf boekt niets; terugbetalen doet de controller, één keer.
      assert grootboekregels(ctx.user) == regels
    end

    test "tegenproef: een gewone bestelling gaat naar :provisioning met een uitrol", ctx do
      attrs = bestelling(ctx)
      vps = wachtende_vps(attrs)
      geheugen = vrij_geheugen(ctx.fleet_node)

      assert {:ok, %{vps: %Vps{status: :provisioning} = geplaatst, command: %Command{} = c}} =
               Provisioning.plaats_en_verstuur(vps, attrs)

      assert c.kind == :provision
      assert c.status == :pending
      assert geplaatst.node_id == ctx.fleet_node.id
      assert is_binary(geplaatst.ip_address)
      assert status(vps.id) == :provisioning
      assert [%PortForward{target_port: 22}] = forwards(vps.id)
      assert [%Reservation{status: :held}] = reserveringen(vps.id)
      assert vrij_geheugen(ctx.fleet_node) == geheugen - 2048
    end

    test "zonder capaciteit blijft een verwijderde VPS ook :deleted", ctx do
      leeg = regio()
      attrs = bestelling(ctx, leeg)
      verouderd = wachtende_vps(attrs)

      assert {:ok, _} = Teardown.delete_vps(verouderd.id)

      assert {:error, :no_capacity} = Provisioning.plaats_en_verstuur(verouderd, attrs)
      assert status(verouderd.id) == :deleted
      assert reserveringen(verouderd.id) == []
    end
  end

  describe "mark_vps_failed/1" do
    test "laat een :deleted VPS :deleted en boekt niets", ctx do
      vps = wachtende_vps(bestelling(ctx))
      Repo.update_all(from(v in Vps, where: v.id == ^vps.id), set: [status: :deleted])
      regels = grootboekregels(ctx.user)

      assert {:ok, nil} = Provisioning.mark_vps_failed(vps)
      assert status(vps.id) == :deleted
      assert grootboekregels(ctx.user) == regels
    end

    test "tegenproef: een wachtende VPS wordt wel :failed", ctx do
      vps = wachtende_vps(bestelling(ctx))

      assert {:ok, %Vps{status: :failed}} = Provisioning.mark_vps_failed(vps)
      assert status(vps.id) == :failed
    end
  end

  describe "fail_and_release_reservation/1" do
    test "laat een :deleted VPS :deleted en geeft niets nog eens vrij", ctx do
      vps = verwijderd_met_vrijgegeven_reservering(ctx)
      geheugen = vrij_geheugen(ctx.fleet_node)
      regels = grootboekregels(ctx.user)

      assert {:ok, %{reservation: nil, restore_capacity: 0}} =
               Provisioning.fail_and_release_reservation(vps.id)

      assert status(vps.id) == :deleted
      assert vrij_geheugen(ctx.fleet_node) == geheugen
      assert [%Reservation{status: :released}] = reserveringen(vps.id)
      assert grootboekregels(ctx.user) == regels
    end

    test "tegenproef: een niet-verwijderde VPS wordt :failed", ctx do
      vps = wachtende_vps(bestelling(ctx))

      assert {:ok, %{vps: %Vps{status: :failed}}} =
               Provisioning.fail_and_release_reservation(vps.id)

      assert status(vps.id) == :failed
    end
  end
end
