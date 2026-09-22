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

  alias ControlPlane.Accounts
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
end
