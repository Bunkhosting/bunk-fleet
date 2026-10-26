defmodule ControlPlaneWeb.Admin.NodeOwnerPanelTest do
  @moduledoc """
  Een node zonder eigenaar krijgt er een via het beheerpaneel, en alleen daar.

  Het zat eerst op `/api/v1/nodes/:id/owner`, als uitzondering voor de rol
  `:admin`. Op die route gold geen tweede factor en geen auditlog: een
  beheerderssessie die met alleen een wachtwoord begon, kon er een node mee
  claimen, en niemand zag het terug.
  """
  use ControlPlaneWeb.ConnCase, async: false

  import ControlPlane.Fixtures, only: [confirmed_user_fixture: 0, with_second_factor: 1]

  alias ControlPlane.Accounts
  alias ControlPlane.Beheer.Audit
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp beheerder(opts) do
    u = confirmed_user_fixture() |> Ecto.Changeset.change(%{role: :admin}) |> Repo.update!()
    u = if opts[:factor], do: with_second_factor(u), else: u

    token =
      u
      |> Accounts.generate_user_session_token(mfa: Keyword.get(opts, :mfa, false))
      |> Base.url_encode64(padding: false)

    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end

  defp node_zonder_eigenaar do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "node-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Repo.insert!()
  end

  test "wijst toe en laat een regel in het auditlog achter" do
    klant = confirmed_user_fixture()
    n = node_zonder_eigenaar()

    beheerder(factor: true, mfa: true)
    |> post(~p"/api/v1/beheer/nodes/#{n.id}/owner", %{"owner_email" => klant.email})
    |> json_response(200)

    assert Repo.get!(Node, n.id).owner_id == klant.id
    assert [regel | _] = Audit.recent(1)
    assert regel.pad == "/api/v1/beheer/nodes/#{n.id}/owner"
  end

  test "een sessie zonder tweede factor komt er niet door" do
    klant = confirmed_user_fixture()
    n = node_zonder_eigenaar()

    beheerder(factor: true, mfa: false)
    |> post(~p"/api/v1/beheer/nodes/#{n.id}/owner", %{"owner_email" => klant.email})
    |> json_response(403)

    assert is_nil(Repo.get!(Node, n.id).owner_id)
  end

  test "een node met eigenaar geeft 409 en blijft van die eigenaar" do
    eigenaar = confirmed_user_fixture()
    n = node_zonder_eigenaar()
    {:ok, _} = NodeAdmin.assign_unowned_node(n.id, eigenaar.id)

    beheerder(factor: true, mfa: true)
    |> post(~p"/api/v1/beheer/nodes/#{n.id}/owner", %{
      "owner_email" => confirmed_user_fixture().email
    })
    |> json_response(409)

    assert Repo.get!(Node, n.id).owner_id == eigenaar.id
  end
end
