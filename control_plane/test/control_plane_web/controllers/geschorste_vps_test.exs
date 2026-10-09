defmodule ControlPlaneWeb.GeschorsteVpsTest do
  @moduledoc """
  Een VPS die stilstaat omdat de verlenging niet betaald kon worden, start de
  klant niet zelf weer.

  Schorsen was alleen een stopcommando. Op de knop Starten drukken maakte dat
  ongedaan, en de VPS draaide dan onbetaald tot de dagelijkse nieuwe poging hem
  weer stopte -- elke dag opnieuw.
  """
  use ControlPlaneWeb.ConnCase, async: true

  import ControlPlane.Fixtures
  import Ecto.Query

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo
  alias ControlPlane.Subscriptions.Subscription

  setup %{conn: conn} do
    user = confirmed_user_fixture()

    token =
      user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)

    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Ecto.Changeset.change(%{
        status: :online,
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
        status: :stopped,
        provider_vm_id: "105",
        owner_id: user.id,
        owner_email: user.email
      })
      |> Repo.insert!()

    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), user: user, vps: vps}
  end

  defp abonnement(user, vps, status) do
    %Subscription{}
    |> Subscription.changeset(%{
      vps_id: vps.id,
      owner_id: user.id,
      package_id: 1,
      price_monthly: Decimal.new("5.00"),
      status: status,
      started_at: DateTime.truncate(DateTime.utc_now(), :second),
      next_billing_date: Date.utc_today()
    })
    |> Repo.insert!()
  end

  defp commandos(vps), do: Repo.all(from c in Command, where: c.vps_id == ^vps.id)

  test "een geschorste VPS start niet en er gaat geen commando uit", %{
    conn: conn,
    user: user,
    vps: vps
  } do
    abonnement(user, vps, :past_due)

    assert %{"error" => "vps_suspended"} =
             conn |> post(~p"/api/v1/vpses/#{vps.id}/start") |> json_response(402)

    assert commandos(vps) == []
  end

  test "een betaalde VPS start gewoon", %{conn: conn, user: user, vps: vps} do
    # De tegenproef: zonder deze zou de test hierboven ook slagen als starten
    # in deze opzet altijd mislukte.
    abonnement(user, vps, :active)

    assert conn |> post(~p"/api/v1/vpses/#{vps.id}/start") |> json_response(200)
    assert [%Command{kind: :start}] = commandos(vps)
  end
end
