defmodule ControlPlane.ProvisioningClosesNodeTest do
  @moduledoc """
  Een ontbrekende template is geen incident maar een toestand. Hij is er niet,
  dus de volgende bestelling op die node faalt precies zo, en de daarna ook --
  terwijl de scheduler zo'n node juist het liefst kiest, want er staat niets op
  en hij heeft dus de meeste vrije ruimte. Op 16 september 2026 kostte dat een
  node die groen stond waar niets op te bestellen viel.

  Deze tests leggen vast dat zo'n mislukking de node sluit, en net zo belangrijk:
  dat een gewone storing dat níét doet.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.NodeAdmin
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Provisioning
  alias ControlPlane.Repo

  defp node_met_vps do
    code = "r-#{System.unique_integer([:positive])}"

    region =
      %Region{} |> Region.changeset(%{code: code, name: "Region #{code}"}) |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: region.id
      })
      |> Ecto.Changeset.change(%{
        status: :online,
        last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second),
        total_vcpu: 32,
        total_ram_mb: 65_536,
        total_disk_gb: 1000,
        available_vcpu: 32,
        available_ram_mb: 65_536,
        available_disk_gb: 1000
      })
      |> Repo.insert!()

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "vps-#{System.unique_integer([:positive])}",
        region_id: region.id,
        node_id: node.id,
        vcpu: 2,
        ram_mb: 4096,
        disk_gb: 50
      })
      |> Ecto.Changeset.put_change(:status, :provisioning)
      |> Repo.insert!()

    {node, vps}
  end

  defp provision_faalt(node, vps, fout) do
    cmd =
      %Command{}
      |> Command.changeset(%{kind: :provision, node_id: node.id, vps_id: vps.id, payload: %{}})
      |> Ecto.Changeset.put_change(:status, :delivered)
      |> Repo.insert!()

    Provisioning.apply_result(cmd, %{"status" => "failed", "error" => fout})
  end

  describe "een bestelling die strandt op de template" do
    test "sluit de node en zet de reden erbij" do
      {node, vps} = node_met_vps()

      assert {:ok, _} =
               provision_faalt(
                 node,
                 vps,
                 "proxmox: clone template 9000: POST /nodes/hw-loon-pve-01/qemu/9000/clone: 500"
               )

      dicht = Repo.get!(Node, node.id)
      assert dicht.status == :draining
      assert dicht.drain_reason =~ "clone template 9000"

      # De VPS zelf blijft gewoon mislukt: de node sluiten verandert niets aan
      # wat er met deze bestelling is gebeurd.
      assert Repo.get!(Vps, vps.id).status == :failed
    end

    test "herkent ook de ESXi-kant" do
      {node, vps} = node_met_vps()

      assert {:ok, _} =
               provision_faalt(node, vps, ~s(esxi: template "bunk-ubuntu-2204": not found))

      assert Repo.get!(Node, node.id).status == :draining
    end

    test "het heropenen wist de reden" do
      # Anders vertelt het paneel de volgende lezer dat er nog iets mis is.
      {node, vps} = node_met_vps()
      assert {:ok, _} = provision_faalt(node, vps, "proxmox: clone template 9000: boom")
      assert Repo.get!(Node, node.id).drain_reason

      assert {:ok, _} = NodeAdmin.resume_node(node.id)

      hersteld = Repo.get!(Node, node.id)
      assert hersteld.status == :online
      assert is_nil(hersteld.drain_reason)
    end
  end

  describe "een gewone storing" do
    test "laat de node open staan" do
      # Dit is de andere helft. Een node dichtzetten voor een volle schijf of een
      # netwerkhapering maakt van een tijdelijke storing een blijvende, en dat is
      # erger dan de mislukte bestelling zelf.
      {node, vps} = node_met_vps()

      assert {:ok, _} = provision_faalt(node, vps, "proxmox: dial tcp: i/o timeout")

      open = Repo.get!(Node, node.id)
      assert open.status == :online
      assert is_nil(open.drain_reason)
    end

    test "een mislukking zonder fouttekst raakt de node niet" do
      {node, vps} = node_met_vps()

      cmd =
        %Command{}
        |> Command.changeset(%{kind: :provision, node_id: node.id, vps_id: vps.id, payload: %{}})
        |> Ecto.Changeset.put_change(:status, :delivered)
        |> Repo.insert!()

      assert {:ok, _} = Provisioning.apply_result(cmd, %{"status" => "failed"})
      assert Repo.get!(Node, node.id).status == :online
    end
  end
end
