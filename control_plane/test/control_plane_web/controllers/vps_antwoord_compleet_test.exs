defmodule ControlPlaneWeb.VpsAntwoordCompleetTest do
  @moduledoc """
  Een VPS ziet er hetzelfde uit, langs welke route je hem ook opvraagt.

  `vps_json/1` leest zijn regio, zijn publieke adres, zijn SSH-poort en zijn
  poortdoorverwijzingen uit associaties. Zaten die er niet in, dan viel elk van
  die velden terug op `nil` of `[]` -- en dat leest als "deze VPS heeft er geen"
  in plaats van "niemand heeft het opgehaald". Twee heel verschillende dingen,
  hetzelfde antwoord.

  Zichtbaar werd het bij herstellen, verwijderen en hernoemen: die geven de
  struct door die de context teruggaf, zonder preload, en daar verdween de regio
  uit het antwoord. Geen klant heeft het gemerkt, omdat het scherm juist die
  antwoorden negeert en opnieuw ophaalt. Dat maakt het niet minder fout: een
  antwoord dat afhangt van de weg erheen is een antwoord waar niemand op kan
  bouwen, en de volgende aanroeper die het wél gebruikt merkt het pas als een
  klant belt dat zijn poortdoorverwijzingen weg zijn.

  Daarom staat het hier per route vast, en niet als één test op de gelukkige weg.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures
  import Ecto.Query, only: [from: 2]

  alias ControlPlane.Accounts
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.PortForward
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  setup %{conn: conn} do
    user = confirmed_user_fixture()

    token =
      user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)

    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Ecto.Changeset.change(%{
        status: :online,
        public_host: "node.example.test",
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "web",
        region_id: region.id,
        node_id: node.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20,
        status: :active,
        owner_id: user.id,
        owner_email: user.email
      })
      |> Repo.insert!()

    Repo.insert!(%PortForward{
      vps_id: vps.id,
      node_id: node.id,
      public_port: 20_022,
      target_port: 22,
      protocol: :tcp,
      purpose: "ssh"
    })

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      vps: vps,
      code: code
    }
  end

  defp compleet?(antwoord, code) do
    antwoord["region"] == code and
      antwoord["location"] == "Regio" and
      antwoord["public_host"] == "node.example.test" and
      antwoord["ssh_port"] == 20_022 and
      length(antwoord["port_forwards"] || []) == 1
  end

  test "het detailscherm geeft alles", %{conn: conn, vps: vps, code: code} do
    # De route die het altijd al goed deed. Staat erbij zodat een reparatie die
    # de andere routes goedmaakt door deze te verslechteren, ook opvalt.
    assert %{"vps" => gevonden} =
             conn |> get(~p"/api/v1/vpses/#{vps.id}") |> json_response(200)

    assert compleet?(gevonden, code), inspect(gevonden)
  end

  test "verwijderen geeft ook een regio terug", %{conn: conn, vps: vps, code: code} do
    # Dit is de route waar het misging, gezien op productie: `delete_vps/1`
    # geeft een verse struct uit zijn transactie terug, zonder associaties, en
    # het antwoord meldde dan `"region": null` voor een VPS die wel degelijk in
    # een regio stond.
    #
    # Alleen op de regio en het publieke adres, niet op de poortdoorverwijzingen:
    # die hóren bij het verwijderen te verdwijnen, en dan zou een lege lijst
    # juist het goede antwoord zijn.
    assert %{"vps" => gevonden} =
             conn |> delete(~p"/api/v1/vpses/#{vps.id}") |> json_response(202)

    assert gevonden["region"] == code, inspect(gevonden)
    assert gevonden["public_host"] == "node.example.test", inspect(gevonden)
  end

  test "hernoemen geeft het hele antwoord", %{conn: conn, vps: vps, code: code} do
    # `Fleet.rename_vps/2` geeft terug wat `Repo.update/1` teruggeeft. Of daar
    # een regio in zit, hangt af van wat de aanroeper toevallig meegaf -- en dat
    # mag niet uitmaken voor wat de klant leest.
    assert %{"vps" => gevonden} =
             conn
             |> patch(~p"/api/v1/vpses/#{vps.id}", %{"name" => "nieuwe naam"})
             |> json_response(200)

    assert gevonden["name"] == "nieuwe naam"
    assert compleet?(gevonden, code), inspect(gevonden)
  end

  test "herstellen geeft het hele antwoord", %{conn: conn, vps: vps, code: code} do
    # `Backups.restore/2` geeft de rij terug die hij onder FOR UPDATE opnieuw
    # las, en zo'n verse rij heeft geen enkele associatie geladen.
    {:ok, vps} = vps |> Ecto.Changeset.change(provider_vm_id: "106") |> Repo.update()
    punt = herstelpunt(vps)

    assert %{"vps" => gevonden} =
             conn
             |> post(~p"/api/v1/vpses/#{vps.id}/backups/#{punt.id}/restore")
             |> json_response(202)

    # Eerst bewijzen dat het herstel echt gelukt is: anders slaagt de rest om de
    # verkeerde reden, op een antwoord dat nooit door dit pad kwam.
    assert gevonden["status"] == "restoring"
    assert compleet?(gevonden, code), inspect(gevonden)
  end

  test "een VPS zonder regio zegt null, en dat betekent dan ook echt geen regio", %{
    conn: conn,
    vps: vps
  } do
    # Dit kan sinds een regio weg mag terwijl er nog VPS'en naar verwezen
    # (`ON DELETE SET NULL`). Rechtstreeks in de rij, want de changeset eist een
    # regio en een regio met een node eraan laat zich niet verwijderen.
    {1, _} = Repo.update_all(from(v in Vps, where: v.id == ^vps.id), set: [region_id: nil])

    assert %{"vps" => gevonden} =
             conn |> get(~p"/api/v1/vpses/#{vps.id}") |> json_response(200)

    # Het pad is gehaald: de rest van het antwoord is er gewoon.
    assert gevonden["public_host"] == "node.example.test", inspect(gevonden)
    assert gevonden["region"] == nil
    assert gevonden["location"] == nil

    assert %{"vpses" => [in_lijst]} = conn |> get(~p"/api/v1/vpses") |> json_response(200)
    assert in_lijst["id"] == vps.id
    assert in_lijst["region"] == nil
  end

  defp herstelpunt(vps) do
    %VpsBackup{}
    |> VpsBackup.changeset(%{
      vps_id: vps.id,
      node_id: vps.node_id,
      status: :done,
      volid: "local:backup/vzdump-qemu-#{System.unique_integer([:positive])}.vma.zst",
      started_at: DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second),
      finished_at: DateTime.utc_now() |> DateTime.add(-3500) |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
