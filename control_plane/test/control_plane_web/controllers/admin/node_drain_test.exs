defmodule ControlPlaneWeb.Admin.NodeDrainTest do
  use ControlPlaneWeb.ConnCase, async: true

  alias ControlPlane.Fleet
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  # Een beheerderssessie, geen gedeeld geheim meer: zie `ConnCase.als_beheerder/1`.
  defp auth(conn), do: conn |> als_beheerder() |> elem(0)

  defp node_fixture do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "R"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  test "drain closes the node and resume reopens it", %{conn: conn} do
    node = node_fixture()

    assert %{"node" => drained} =
             conn |> auth() |> post(~p"/admin/v1/nodes/#{node.id}/drain") |> json_response(200)

    assert drained["status"] == "draining"
    assert Repo.get!(Node, node.id).status == :draining

    assert %{"node" => resumed} =
             conn |> auth() |> post(~p"/admin/v1/nodes/#{node.id}/resume") |> json_response(200)

    assert resumed["status"] == "online"
  end

  test "requires an admin session", %{conn: conn} do
    node = node_fixture()
    conn = post(conn, ~p"/admin/v1/nodes/#{node.id}/drain")
    assert conn.status in [401, 403]
  end

  test "an unknown or malformed id is 404, never a 500", %{conn: conn} do
    assert conn
           |> auth()
           |> post(~p"/admin/v1/nodes/#{Ecto.UUID.generate()}/drain")
           |> json_response(404)

    assert conn |> auth() |> post(~p"/admin/v1/nodes/not-a-uuid/drain") |> json_response(404)
  end

  test "resuming a node that is offline is refused rather than forcing it online", %{conn: conn} do
    # A node that is not heartbeating is not something an operator can talk back
    # into service; the reconciler decides that, from evidence.
    node = node_fixture()
    {:ok, _} = node |> Node.mark_online_changeset(%{status: :offline}) |> Repo.update()

    assert %{"error" => "invalid_status_offline"} =
             conn |> auth() |> post(~p"/admin/v1/nodes/#{node.id}/resume") |> json_response(409)
  end

  test "an offline node can still be drained", %{conn: conn} do
    # Draining something that is already down is how you stop it coming back into
    # rotation the moment it recovers.
    node = node_fixture()
    {:ok, _} = node |> Node.mark_online_changeset(%{status: :offline}) |> Repo.update()

    assert %{"node" => %{"status" => "draining"}} =
             conn |> auth() |> post(~p"/admin/v1/nodes/#{node.id}/drain") |> json_response(200)

    assert {:ok, %Node{status: :draining}} = Fleet.drain_node(node.id)
  end
end
