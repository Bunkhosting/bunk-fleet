defmodule ControlPlane.AfbraakRobuustheidTest do
  @moduledoc """
  Drie gaten in het afbreken van VPS'en.

  Een tweede verwijderverzoek op een uitgestelde afbraak stuurde een delete
  zonder vm_id naar de node; meldde de agent die als klaar, dan stond de VPS op
  `:deleted` terwijl de uitrol de VM daarna nog kon afmaken. En een mislukte
  afbraak van een wees-VM (VPS al `:deleted`) werd nooit herhaald, omdat
  `retry_stuck_deletes/2` alleen naar `:deleting` kijkt.
  """
  # Niet async: de melding na het maximum leest OPS_EMAIL uit de app-config.
  use ControlPlane.DataCase, async: false

  import Swoosh.TestAssertions

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Provisioning.CommandQueue
  alias ControlPlane.Provisioning.Teardown

  setup do
    vorig = Application.get_env(:control_plane, :ops_email)
    Application.put_env(:control_plane, :ops_email, "ops@bunk.test")

    on_exit(fn ->
      case vorig do
        nil -> Application.delete_env(:control_plane, :ops_email)
        waarde -> Application.put_env(:control_plane, :ops_email, waarde)
      end
    end)

    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()

    fleet_node =
      %Node{}
      |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
      |> Ecto.Changeset.change(%{
        status: :online,
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    %{region: region, fleet_node: fleet_node}
  end

  defp vm_id, do: "#{1000 + System.unique_integer([:positive])}"

  defp vps(ctx, status, provider_vm_id) do
    %Vps{}
    |> Vps.changeset(%{
      name: "v-#{System.unique_integer([:positive])}",
      region_id: ctx.region.id,
      node_id: ctx.fleet_node.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 10,
      provider_vm_id: provider_vm_id
    })
    |> Ecto.Changeset.put_change(:status, status)
    |> Repo.insert!()
  end

  defp commando(vps, kind, status, payload, age_seconds \\ 0) do
    at = DateTime.utc_now() |> DateTime.add(-age_seconds, :second) |> DateTime.truncate(:second)

    %Command{}
    |> Command.changeset(%{
      node_id: vps.node_id,
      vps_id: vps.id,
      kind: kind,
      status: status,
      payload: payload
    })
    |> Ecto.Changeset.change(%{inserted_at: at, updated_at: at})
    |> Repo.insert!()
  end

  defp mislukte_delete(vps, vm_id, age_seconds),
    do: commando(vps, :delete, :failed, %{"vm_id" => vm_id}, age_seconds)

  defp deletes(vps_id) do
    Repo.all(from c in Command, where: c.vps_id == ^vps_id and c.kind == :delete)
  end

  defp deletes_zonder_vm_id_voor(fleet_node) do
    fleet_node
    |> CommandQueue.deliverable_commands_for_node()
    |> Enum.filter(&(&1.kind == :delete and not is_binary(&1.payload["vm_id"])))
  end

  describe "opnieuw verwijderen van een :deleting VPS" do
    test "een tweede verzoek op een uitgestelde afbraak stuurt geen commando", ctx do
      v = vps(ctx, :provisioning, nil)
      commando(v, :provision, :delivered, %{})

      assert {:ok, %{command: nil, vps: %Vps{status: :deleting}}} = Teardown.delete_vps(v.id)

      # Het pad moet echt gehaald zijn: de VPS staat op een uitgestelde afbraak.
      assert %Vps{status: :deleting, provider_vm_id: nil} = Repo.get!(Vps, v.id)

      assert {:error, :already_deleting} = Teardown.delete_vps(v.id)
      assert {:error, :already_deleting} = Teardown.delete_vps(v.id)

      assert deletes(v.id) == []
      assert deletes_zonder_vm_id_voor(ctx.fleet_node) == []
      assert Repo.get!(Vps, v.id).status == :deleting
    end

    test "tegenproef: zonder lopende uitrol wordt hij lokaal afgesloten, zonder agent", ctx do
      v = vps(ctx, :deleting, nil)

      assert {:ok, %{command: nil}} = Teardown.delete_vps(v.id)
      assert Repo.get!(Vps, v.id).status == :deleted
      assert deletes(v.id) == []
    end

    test "tegenproef: met een VM gaat er na een mislukte afbraak wel een nieuwe uit", ctx do
      id = vm_id()
      v = vps(ctx, :deleting, id)
      commando(v, :delete, :failed, %{"vm_id" => id}, 3600)

      assert {:ok, %{command: %Command{kind: :delete, payload: %{"vm_id" => ^id}}}} =
               Teardown.delete_vps(v.id)
    end

    test "retry_stuck_deletes stuurt geen delete voor een :deleting VPS zonder VM", ctx do
      v = vps(ctx, :deleting, nil)
      Repo.insert!(%Command{node_id: v.node_id, vps_id: v.id, kind: :delete, status: :failed})

      assert Teardown.retry_stuck_deletes(0) == 0
      assert deletes_zonder_vm_id_voor(ctx.fleet_node) == []
    end
  end

  describe "een delete zonder vm_id" do
    test "wordt door de changeset geweigerd", ctx do
      v = vps(ctx, :active, vm_id())

      for payload <- [%{}, %{"vm_id" => nil}, %{"vm_id" => ""}] do
        changeset =
          Command.changeset(%Command{}, %{
            node_id: v.node_id,
            vps_id: v.id,
            kind: :delete,
            payload: payload
          })

        refute changeset.valid?
        assert %{payload: [_]} = errors_on(changeset)
      end
    end

    test "tegenproef: met vm_id, of een ander soort commando, mag het wel", ctx do
      v = vps(ctx, :active, vm_id())
      base = %{node_id: v.node_id, vps_id: v.id}

      met_vm = Map.merge(base, %{kind: :delete, payload: %{"vm_id" => "1"}})
      uitrol = Map.merge(base, %{kind: :provision, payload: %{}})

      assert Command.changeset(%Command{}, met_vm).valid?
      assert Command.changeset(%Command{}, uitrol).valid?
    end

    test "een oude rij zonder vm_id kan nog wel een resultaat krijgen", ctx do
      # Van voor deze regel: hij moet terminal kunnen worden, anders deelt de
      # wachtrij hem eeuwig opnieuw uit.
      v = vps(ctx, :deleting, nil)

      oud = Repo.insert!(%Command{node_id: v.node_id, vps_id: v.id, kind: :delete, payload: %{}})

      assert {:ok, _} = Provisioning.apply_result(oud, %{"status" => "failed", "error" => "x"})
      assert Repo.get!(Command, oud.id).status == :failed
    end
  end

  describe "mislukte afbraak van een wees-VM" do
    test "wordt opnieuw ingepland zodra de wachttijd om is", ctx do
      id = vm_id()
      v = vps(ctx, :deleted, id)
      commando(v, :delete, :failed, %{"vm_id" => id}, 3600)

      assert Teardown.retry_orphan_deletes(300) == 1

      assert [%Command{node_id: node_id, payload: %{"vm_id" => ^id}}] =
               Enum.filter(deletes(v.id), &(&1.status == :pending))

      assert node_id == ctx.fleet_node.id

      # Een lopende poging wordt niet verdubbeld.
      assert Teardown.retry_orphan_deletes(300) == 0
    end

    test "tegenproef: een mislukking van zojuist wacht nog", ctx do
      id = vm_id()
      v = vps(ctx, :deleted, id)
      commando(v, :delete, :failed, %{"vm_id" => id}, 10)

      assert Teardown.retry_orphan_deletes(300) == 0
      assert Enum.all?(deletes(v.id), &(&1.status == :failed))
    end

    test "de wachttijd verdubbelt per mislukking, net als bij retry_stuck_deletes", ctx do
      # Vier mislukkingen: de volgende wacht 5 * 2^3 = 40 minuten. De nieuwste
      # is 20 minuten oud, dus nog niet aan de beurt -- bij één mislukking was
      # hij dat na vijf minuten wel geweest.
      id = vm_id()
      v = vps(ctx, :deleted, id)
      for age <- [9000, 8000, 7000, 1200], do: mislukte_delete(v, id, age)

      assert Teardown.retry_orphan_deletes(300) == 0

      # Dezelfde vier, de nieuwste 50 minuten oud: wel aan de beurt.
      id2 = vm_id()
      w = vps(ctx, :deleted, id2)
      for age <- [9000, 8000, 7000, 3000], do: mislukte_delete(w, id2, age)

      assert Teardown.retry_orphan_deletes(300) == 1
      assert Enum.any?(deletes(w.id), &(&1.status == :pending))
      refute Enum.any?(deletes(v.id), &(&1.status == :pending))
    end

    test "na het maximum volgt één melding en geen nieuwe poging", ctx do
      id = vm_id()
      v = vps(ctx, :deleted, id)

      for age <- [90_000, 80_000, 70_000, 60_000, 50_000, 40_000], do: mislukte_delete(v, id, age)

      assert Teardown.retry_orphan_deletes(300) == 0
      assert_email_sent(subject: "[Bunk] Wees-VM #{id} laat zich niet afbreken")
      assert Enum.all?(deletes(v.id), &(&1.status == :failed))

      # De volgende ronde: geen poging, en geen tweede melding.
      assert Teardown.retry_orphan_deletes(300) == 0
      refute_email_sent()
      assert Enum.all?(deletes(v.id), &(&1.status == :failed))
    end

    test "tegenproef: één onder het maximum wordt nog wel herhaald, zonder melding", ctx do
      id = vm_id()
      v = vps(ctx, :deleted, id)

      for age <- [90_000, 80_000, 70_000, 60_000, 50_000], do: mislukte_delete(v, id, age)

      assert Teardown.retry_orphan_deletes(300) == 1
      refute_email_sent()
    end

    test "tegenproef: een geslaagde opvolger maakt het af", ctx do
      id = vm_id()
      v = vps(ctx, :deleted, id)
      commando(v, :delete, :failed, %{"vm_id" => id}, 7200)
      commando(v, :delete, :done, %{"vm_id" => id}, 3600)

      assert Teardown.retry_orphan_deletes(300) == 0
    end

    test "tegenproef: een VM-nummer dat weer bij een levende VPS hoort, blijft staan", ctx do
      id = vm_id()
      v = vps(ctx, :deleted, id)
      commando(v, :delete, :failed, %{"vm_id" => id}, 3600)
      _levend = vps(ctx, :active, id)

      assert Teardown.retry_orphan_deletes(300) == 0
    end

    test "tegenproef: een VPS die nog op :deleting staat is niet van deze ronde", ctx do
      id = vm_id()
      v = vps(ctx, :deleting, id)
      commando(v, :delete, :failed, %{"vm_id" => id}, 3600)

      assert Teardown.retry_orphan_deletes(300) == 0
      assert Teardown.retry_stuck_deletes(300) == 1
    end

    test "tegenproef: een mislukking van langer dan een week geleden blijft liggen", ctx do
      id = vm_id()
      v = vps(ctx, :deleted, id)
      commando(v, :delete, :failed, %{"vm_id" => id}, 8 * 24 * 3600)

      assert Teardown.retry_orphan_deletes(300) == 0
    end
  end
end
