defmodule ControlPlane.VpsZonderRegioTest do
  @moduledoc """
  Een VPS waarvan de regio is opgeruimd, blijft een rij die je kunt bijwerken.

  Sinds `vpses.region_id` op `ON DELETE SET NULL` staat, kan een VPS zonder
  regio bestaan. `Vps.changeset/2` eiste de regio bij elke wijziging, en dan
  liep alles vast wat daarna die rij aanraakte: hernoemen, een statusovergang,
  een delete-verzoek, een antwoord van de agent.

  De regio is alleen verplicht bij het aanmaken. Dat staat hier ook vast, als
  tegenproef: zonder die zou "nooit meer verplicht" ook groen zijn.
  """
  use ControlPlane.DataCase, async: true

  import ControlPlane.Fixtures

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Regions
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Provisioning.Power
  alias ControlPlane.Provisioning.Teardown

  defp regio do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "Regio #{code}"}) |> Repo.insert!()
  end

  defp fleet_node(region) do
    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  # Een draaiende VPS waarvan de regio daarna leeg is gezet. In productie
  # gebeurt dat alleen met een verwijderde VPS (`Regions.delete_region/1` weigert
  # anders); hier met een draaiende, zodat ook de statuspaden aan bod komen.
  defp vps_zonder_regio(status \\ :active) do
    r = regio()
    user = confirmed_user_fixture()

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "web",
        region_id: r.id,
        node_id: fleet_node(r).id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 10,
        status: status,
        provider_vm_id: "#{100 + System.unique_integer([:positive])}",
        owner_id: user.id,
        owner_email: user.email
      })
      |> Repo.insert!()

    {1, _} = Repo.update_all(from(v in Vps, where: v.id == ^vps.id), set: [region_id: nil])

    zonder = Repo.get!(Vps, vps.id)
    # Eerst vastleggen dat de toestand er echt is; anders slaagt alles
    # hieronder ook als het opzetten stil iets anders deed.
    assert is_nil(zonder.region_id)
    zonder
  end

  test "hernoemen lukt" do
    vps = vps_zonder_regio()

    assert {:ok, hernoemd} = Fleet.rename_vps(vps, "nieuwe naam")
    assert hernoemd.name == "nieuwe naam"
    assert is_nil(Repo.get!(Vps, vps.id).region_id)
  end

  test "een gewone statusovergang lukt" do
    vps = vps_zonder_regio()

    for status <- [:stopped, :active, :failed, :deleting, :deleted] do
      assert {:ok, %Vps{status: ^status}} =
               Repo.get!(Vps, vps.id) |> Vps.changeset(%{status: status}) |> Repo.update()
    end
  end

  test "een agentresultaat voor een machtscommando komt aan" do
    vps = vps_zonder_regio()

    assert {:ok, %{command: %Command{} = cmd}} = Power.stop_vps(vps.id)
    assert {:ok, %Command{status: :done}} = Provisioning.apply_result(cmd, %{"status" => "done"})
    assert Repo.get!(Vps, vps.id).status == :stopped
  end

  test "verwijderen: het verzoek en het antwoord van de agent komen allebei aan" do
    vps = vps_zonder_regio()

    assert {:ok, %{vps: %Vps{status: :deleting}, command: %Command{} = cmd}} =
             Teardown.delete_vps(vps.id)

    assert {:ok, %Command{status: :done}} = Provisioning.apply_result(cmd, %{"status" => "done"})
    assert Repo.get!(Vps, vps.id).status == :deleted
  end

  test "een mislukte VPS zonder regio kan worden opgeruimd" do
    vps = vps_zonder_regio(:failed)

    assert {:ok, %{vps: %Vps{status: :deleted}, command: nil}} = Teardown.delete_vps(vps.id)
  end

  test "het echte pad: een verwijderde VPS uit een opgeruimde regio blijft bij te werken" do
    # Zoals het in productie ontstaat: de VPS is weg, de regio daarna ook.
    r = regio()

    vps =
      %Vps{}
      |> Vps.changeset(%{name: "oud", region_id: r.id, vcpu: 1, ram_mb: 1024, disk_gb: 10})
      |> Ecto.Changeset.put_change(:status, :deleted)
      |> Repo.insert!()

    assert Regions.delete_region(r.id) == :ok
    vps = Repo.get!(Vps, vps.id)
    assert is_nil(vps.region_id)

    # Een laat antwoord op een uitrol legt het VM-id vast op precies deze manier
    # (zie `settle_provisioned_vps/4`).
    assert {:ok, %Vps{provider_vm_id: "4242"}} =
             vps |> Vps.changeset(%{provider_vm_id: "4242"}) |> Repo.update()
  end

  describe "tegenproef" do
    test "aanmaken zonder regio wordt nog steeds geweigerd" do
      changeset = Vps.changeset(%Vps{}, %{name: "web", vcpu: 1, ram_mb: 1024, disk_gb: 10})

      refute changeset.valid?
      assert %{region_id: ["can't be blank"]} = errors_on(changeset)
      assert {:error, _} = Repo.insert(changeset)
    end

    test "een VPS die een regio heeft, raakt die niet kwijt via een wijziging" do
      r = regio()

      vps =
        %Vps{}
        |> Vps.changeset(%{name: "web", region_id: r.id, vcpu: 1, ram_mb: 1024, disk_gb: 10})
        |> Repo.insert!()

      changeset = Vps.changeset(vps, %{region_id: nil})

      refute changeset.valid?
      assert %{region_id: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
