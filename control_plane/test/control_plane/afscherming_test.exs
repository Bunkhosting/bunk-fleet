defmodule ControlPlane.AfschermingTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet.Afscherming
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  @notitie "klanten op deze node zijn niet van elkaar afgeschermd (Datacenter > Firewall > Opties > Firewall: Ja)"

  defp node_met(notitie) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "R"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{status: :online, network_note: notitie})
    |> Repo.insert!()
  end

  defp klant do
    {:ok, u} =
      Accounts.register_user(%{
        email: "k-#{System.unique_integer([:positive])}@bunk.test",
        password: "test-only-password-4f2b9c1e"
      })

    u
  end

  defp vps_op(node, eigenaar) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: node.region_id,
      node_id: node.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      status: :active
    })
    |> Ecto.Changeset.change(%{owner_id: eigenaar.id})
    |> Repo.insert!()
  end

  test "een node met de notitie en twee klanten wordt gemeld" do
    n = node_met(@notitie)
    vps_op(n, klant())
    vps_op(n, klant())

    assert [{gemeld, 2}] = Afscherming.te_melden()
    assert gemeld.id == n.id
  end

  test "met één klant is er niemand om van af te schermen" do
    n = node_met(@notitie)
    k = klant()
    vps_op(n, k)
    vps_op(n, k)

    assert Afscherming.te_melden() == []
  end

  test "een notitie over iets anders telt niet" do
    n = node_met("bridge vmbr1 bestaat niet")
    vps_op(n, klant())
    vps_op(n, klant())

    assert Afscherming.te_melden() == []
  end
end
