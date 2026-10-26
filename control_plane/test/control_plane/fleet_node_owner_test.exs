defmodule ControlPlane.FleetNodeOwnerTest do
  @moduledoc """
  Wie een node beheert.

  Tot nu toe stond dat nergens vast: een node had alleen `owner_email`, een los
  tekstveld dat als kostenplaats dient, en het enroll-token wist wel wie hem had
  gemunt maar gaf dat niet door. Zonder eigenaar betekent "alleen de eigenaar mag
  de instellingen wijzigen" dat niemand iets mag.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Repo

  defp gebruiker(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    u
  end

  defp fleet_node(attrs \\ %{}) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Node{}
    |> Node.changeset(
      Map.merge(
        %{name: "node-#{System.unique_integer([:positive])}", region_id: region.id},
        attrs
      )
    )
    |> Ecto.Changeset.change(%{
      status: :online,
      last_heartbeat_at: ControlPlane.Clock.now()
    })
    |> Repo.insert!()
  end

  describe "toewijzen en overdragen" do
    test "het beheerpaneel wijst een node zonder eigenaar toe" do
      # Het enige moment waarop iemand anders dan de eigenaar erover gaat. Zonder
      # dit zou een node die met een beheerderstoken is ingeschreven nooit een
      # eigenaar kunnen krijgen.
      u = gebruiker("eigenaar1@bunk.test")
      n = fleet_node()

      assert {:ok, bijgewerkt} = NodeAdmin.assign_unowned_node(n.id, u.id)
      assert bijgewerkt.owner_id == u.id
    end

    test "een node met eigenaar kan het beheerpaneel niet toewijzen" do
      eigenaar = gebruiker("eigenaar1b@bunk.test")
      n = fleet_node()
      {:ok, n} = NodeAdmin.assign_unowned_node(n.id, eigenaar.id)

      assert {:error, :already_owned} =
               NodeAdmin.assign_unowned_node(n.id, gebruiker("ander@bunk.test").id)

      assert Repo.get!(Node, n.id).owner_id == eigenaar.id
    end

    test "een beheerder claimt een node zonder eigenaar niet langs de eigenaarsroute" do
      # Daar gold geen tweede factor en geen auditlog; dat hoort in het beheerpaneel.
      {:ok, beheerder} = Accounts.update_user_role(gebruiker("adm1@bunk.test"), :admin)
      n = fleet_node()

      assert {:error, :forbidden} = NodeAdmin.assign_node_owner(n.id, beheerder, beheerder.id)
      assert is_nil(Repo.get!(Node, n.id).owner_id)
    end

    test "een gewone gebruiker kan een node zonder eigenaar niet claimen" do
      # Anders pakt de eerste de beste een machine die niet van hem is.
      n = fleet_node()
      dief = gebruiker("dief@bunk.test")

      assert {:error, :forbidden} = NodeAdmin.assign_node_owner(n.id, dief, dief.id)
    end

    test "de eigenaar draagt zijn eigen node over" do
      eigenaar = gebruiker("eigenaar2@bunk.test")
      opvolger = gebruiker("opvolger@bunk.test")
      n = fleet_node()
      {:ok, n} = NodeAdmin.assign_unowned_node(n.id, eigenaar.id)

      assert {:ok, bijgewerkt} = NodeAdmin.assign_node_owner(n.id, eigenaar, opvolger.id)
      assert bijgewerkt.owner_id == opvolger.id
    end

    test "een beheerder kan een node met eigenaar NIET overdragen" do
      # Dit is de regel waar het om gaat: zodra er een eigenaar is, gaat alleen
      # die erover -- ook een beheerder niet.
      {:ok, beheerder} = Accounts.update_user_role(gebruiker("adm3@bunk.test"), :admin)
      eigenaar = gebruiker("eigenaar3@bunk.test")
      n = fleet_node()
      {:ok, n} = NodeAdmin.assign_unowned_node(n.id, eigenaar.id)

      assert {:error, :forbidden} = NodeAdmin.assign_node_owner(n.id, beheerder, beheerder.id)
      assert Repo.get!(Node, n.id).owner_id == eigenaar.id
    end

    test "een andere gebruiker kan een node met eigenaar niet overnemen" do
      eigenaar = gebruiker("eigenaar4@bunk.test")
      vreemde = gebruiker("vreemde@bunk.test")
      n = fleet_node()
      {:ok, n} = NodeAdmin.assign_unowned_node(n.id, eigenaar.id)

      assert {:error, :forbidden} = NodeAdmin.assign_node_owner(n.id, vreemde, vreemde.id)
    end

    test "de eigenaar kan zijn node eigenaarloos maken" do
      eigenaar = gebruiker("eigenaar5@bunk.test")
      n = fleet_node()
      {:ok, n} = NodeAdmin.assign_unowned_node(n.id, eigenaar.id)

      assert {:ok, bijgewerkt} = NodeAdmin.assign_node_owner(n.id, eigenaar, nil)
      assert is_nil(bijgewerkt.owner_id)
    end

    test "weigert een gebruiker die niet bestaat" do
      n = fleet_node()

      assert {:error, :unknown_user} = NodeAdmin.assign_unowned_node(n.id, Ecto.UUID.generate())

      assert is_nil(Repo.get!(Node, n.id).owner_id)
    end

    test "weigert een node die niet bestaat" do
      {:ok, beheerder} = Accounts.update_user_role(gebruiker("adm7@bunk.test"), :admin)

      assert {:error, :not_found} =
               NodeAdmin.assign_node_owner(Ecto.UUID.generate(), beheerder, beheerder.id)
    end
  end

  describe "mag deze gebruiker de instellingen wijzigen" do
    test "de eigenaar wel" do
      u = gebruiker("eigenaar4@bunk.test")
      n = fleet_node()
      n = Repo.update!(Ecto.Changeset.change(n, owner_id: u.id))

      assert NodeAdmin.node_owner?(n, u)
    end

    test "een ander niet, ook geen beheerder" do
      # Bewust: een beheerder die erbij moet draagt de node eerst aan zichzelf
      # over. Dat laat een spoor na, en een noodluik dat niemand ziet is er geen.
      eigenaar = gebruiker("eigenaar5@bunk.test")
      {:ok, beheerder} = Accounts.update_user_role(gebruiker("beheerder@bunk.test"), :admin)
      n = fleet_node()
      n = Repo.update!(Ecto.Changeset.change(n, owner_id: eigenaar.id))

      refute NodeAdmin.node_owner?(n, beheerder)
    end

    test "een node zonder eigenaar is van niemand" do
      # Niet van iedereen: zonder eigenaar hoort niemand aan de instellingen te
      # kunnen komen tot een beheerder hem heeft toegewezen.
      u = gebruiker("eigenaar6@bunk.test")

      refute NodeAdmin.node_owner?(fleet_node(), u)
    end

    test "niet ingelogd is nooit de eigenaar" do
      n = fleet_node()
      n = Repo.update!(Ecto.Changeset.change(n, owner_id: gebruiker("eigenaar7@bunk.test").id))

      refute NodeAdmin.node_owner?(n, nil)
    end
  end
end
