defmodule ControlPlaneWeb.PackageBeschikbaarheidTest do
  @moduledoc """
  `GET /packages` zegt per pakket of er nu een node is die het kan hosten, met
  dezelfde regel als de scheduler. Zonder dat koos een klant een pakket dat nergens
  past en hoorde hij het pas na het bestellen (409 no_capacity).
  """
  use ControlPlaneWeb.ConnCase, async: true

  import Ecto.Query

  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Package
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Scheduler
  alias ControlPlane.Repo

  setup do
    region = insert_region("Regio")
    naam = "Pakket-#{System.unique_integer([:positive])}"

    Repo.insert!(%Package{
      name: naam,
      cpu_cores: 4,
      ram_gb: 8,
      disk_gb: 80,
      price_monthly: Decimal.new("20.00"),
      is_available: true
    })

    %{region: region, naam: naam}
  end

  defp insert_region(naam) do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: naam}) |> Repo.insert!()
  end

  defp insert_node(region, attrs \\ %{}) do
    base = %{
      name: "node-#{System.unique_integer([:positive])}",
      region_id: region.id,
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second),
      total_vcpu: 16,
      total_ram_mb: 32_768,
      total_disk_gb: 500,
      available_vcpu: 16,
      available_ram_mb: 32_768,
      available_disk_gb: 500
    }

    attrs = Map.merge(base, attrs)

    # Node.changeset zet niet alles; status, hartslag en capaciteit forceren we.
    %Node{}
    |> Node.changeset(attrs)
    |> Ecto.Changeset.change(Map.drop(attrs, [:name, :region_id]))
    |> Repo.insert!()
  end

  defp beschikbaar(conn, naam) do
    %{"results" => results} = conn |> get(~p"/api/v1/packages") |> json_response(200)
    results |> Enum.find(&(&1["name"] == naam)) |> Map.fetch!("available")
  end

  test "een pakket dat op een online node past is beschikbaar", %{
    conn: conn,
    region: region,
    naam: naam
  } do
    insert_node(region)
    assert beschikbaar(conn, naam) == true
  end

  test "past alleen op schijf niet, dan is het niet beschikbaar", %{
    conn: conn,
    region: region,
    naam: naam
  } do
    insert_node(region, %{available_disk_gb: 79})
    assert beschikbaar(conn, naam) == false
  end

  test "een offline node met genoeg ruimte telt niet mee", %{
    conn: conn,
    region: region,
    naam: naam
  } do
    insert_node(region, %{status: :offline})
    assert beschikbaar(conn, naam) == false
  end

  test "een node zonder recente hartslag telt niet mee", %{
    conn: conn,
    region: region,
    naam: naam
  } do
    oud = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    insert_node(region, %{last_heartbeat_at: oud})
    assert beschikbaar(conn, naam) == false
  end

  test "een te lage gemelde vrije capaciteit blokkeert het pakket", %{
    conn: conn,
    region: region,
    naam: naam
  } do
    insert_node(region, %{reported_avail_ram_mb: 4096})
    assert beschikbaar(conn, naam) == false
  end

  test "een node in een andere regio telt ook mee", %{conn: conn, naam: naam} do
    insert_node(insert_region("Elders"))
    assert beschikbaar(conn, naam) == true
  end

  test "het antwoord bevat alleen de boolean, geen capaciteit van nodes", %{
    conn: conn,
    region: region,
    naam: naam
  } do
    insert_node(region)
    %{"results" => results} = conn |> get(~p"/api/v1/packages") |> json_response(200)
    pakket = Enum.find(results, &(&1["name"] == naam))

    assert is_boolean(pakket["available"])
    refute Map.has_key?(pakket, "available_vcpu")
    refute Map.has_key?(pakket, "reported_avail_ram_mb")
  end

  describe "fits?/2 en fits_condition/1 zijn dezelfde regel" do
    test "geven voor elke combinatie hetzelfde antwoord", %{region: region} do
      aanvraag = %{vcpu: 4, ram_mb: 8192, disk_gb: 80}

      beschikbaar_varianten = [
        %{},
        %{available_vcpu: 3},
        %{available_ram_mb: 8191},
        %{available_disk_gb: 79}
      ]

      gemeld_varianten = [
        %{},
        %{reported_avail_vcpu: 3},
        %{reported_avail_ram_mb: 8192, reported_avail_disk_gb: 80},
        %{reported_avail_disk_gb: 79}
      ]

      nodes =
        for avail <- beschikbaar_varianten, gemeld <- gemeld_varianten do
          insert_node(region, Map.merge(avail, gemeld))
        end

      in_db =
        Node
        |> where(^Scheduler.fits_condition(aanvraag))
        |> Repo.all()
        |> MapSet.new(& &1.id)

      in_geheugen =
        nodes |> Enum.filter(&Scheduler.fits?(&1, aanvraag)) |> MapSet.new(& &1.id)

      # Beide kanten moeten ook echt iets uitsluiten, anders bewijst dit niets.
      assert MapSet.size(in_geheugen) > 0
      assert MapSet.size(in_geheugen) < length(nodes)
      assert in_db == in_geheugen
    end
  end
end
