defmodule ControlPlane.BackupsTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Backups
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Fleet.Command
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps

  defp region do
    code = "r-#{System.unique_integer([:positive])}"
    %Region{} |> Region.changeset(%{code: code, name: "R #{code}"}) |> Repo.insert!()
  end

  defp node_in(region, status \\ :online) do
    %Node{}
    |> Node.changeset(%{name: "n-#{System.unique_integer([:positive])}", region_id: region.id})
    |> Ecto.Changeset.change(%{
      status: status,
      last_heartbeat_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  defp vps(region, node, attrs \\ %{}) do
    %Vps{}
    |> Vps.changeset(
      Map.merge(
        %{
          name: "v-#{System.unique_integer([:positive])}",
          region_id: region.id,
          node_id: node.id,
          vcpu: 1,
          ram_mb: 1024,
          disk_gb: 10,
          status: :active,
          provider_vm_id: "#{100 + System.unique_integer([:positive])}"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp backup(vps, attrs) do
    %VpsBackup{}
    |> VpsBackup.changeset(Map.merge(%{vps_id: vps.id, node_id: vps.node_id}, attrs))
    |> Repo.insert!()
  end

  defp commands_for(vps_id, kind) do
    Repo.all(from c in Command, where: c.vps_id == ^vps_id and c.kind == ^kind)
  end

  defp ago(seconds) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
  end

  describe "which VPSes are due" do
    test "an active VPS with no backup is due" do
      r = region()
      machine = vps(r, node_in(r))

      assert %{started: 1, errors: 0} = Backups.run_due()
      assert [%Command{kind: :backup}] = commands_for(machine.id, :backup)
    end

    test "one backed up recently is not" do
      r = region()
      machine = vps(r, node_in(r))
      backup(machine, %{status: :done, started_at: ago(60), finished_at: ago(30)})

      assert %{started: 0} = Backups.run_due()
      assert [] = commands_for(machine.id, :backup)
    end

    test "one backed up longer ago than the interval is due again" do
      r = region()
      machine = vps(r, node_in(r))

      backup(machine, %{
        status: :done,
        started_at: ago(Backups.interval_seconds() + 3600),
        finished_at: ago(Backups.interval_seconds() + 3500)
      })

      assert %{started: 1} = Backups.run_due()
    end

    test "one whose backup is still running is left alone, however old" do
      # A second vzdump of the same guest would fight the first for the node's
      # disk, and the customer would feel both.
      r = region()
      machine = vps(r, node_in(r))
      backup(machine, %{status: :running, started_at: ago(Backups.interval_seconds() * 5)})

      assert %{started: 0} = Backups.run_due()
    end

    test "a failed backup does not stop the next one being due" do
      r = region()
      machine = vps(r, node_in(r))

      backup(machine, %{
        status: :failed,
        error: "storage full",
        started_at: ago(Backups.interval_seconds() + 60),
        finished_at: ago(Backups.interval_seconds() + 30)
      })

      assert %{started: 1} = Backups.run_due()
    end

    test "a VPS that is not running is not backed up" do
      r = region()
      node = node_in(r)
      vps(r, node, %{status: :stopped})
      vps(r, node, %{status: :failed})

      assert %{started: 0} = Backups.run_due()
    end

    test "a VPS with no guest behind it yet is skipped" do
      r = region()
      vps(r, node_in(r), %{provider_vm_id: nil, status: :active})

      assert %{started: 0} = Backups.run_due()
    end

    test "a VPS on an offline node is skipped, one on a draining node is not" do
      # Draining means closed to new VPSes, not abandoned: what is still running
      # there still deserves its backup.
      r = region()
      vps(r, node_in(r, :offline))
      on_draining = vps(r, node_in(r, :draining))

      assert %{started: 1} = Backups.run_due()
      assert [_] = commands_for(on_draining.id, :backup)
    end
  end

  describe "recording what the node reported" do
    test "a successful backup records the archive" do
      r = region()
      machine = vps(r, node_in(r))
      {:ok, tracked} = Backups.start_backup(machine)

      {:ok, saved} =
        Backups.record_result(tracked.id, %{
          "status" => "done",
          "volid" => "local:backup/vzdump-qemu-106-2026_09_11.vma.zst",
          "size_bytes" => 1_234_567
        })

      assert saved.status == :done
      assert saved.size_bytes == 1_234_567
      refute is_nil(saved.finished_at)
    end

    test "a failure is written down, not dropped" do
      # "The last three nightly backups failed" is the most useful thing this
      # table can say, and it can only say it if failures are rows.
      r = region()
      machine = vps(r, node_in(r))
      {:ok, tracked} = Backups.start_backup(machine)

      {:ok, saved} =
        Backups.record_result(tracked.id, %{"status" => "failed", "error" => "storage full"})

      assert saved.status == :failed
      assert saved.error == "storage full"
      assert [^saved] = Backups.list_for_vps(machine.id)
    end

    test "a size reported as a string is still a size" do
      r = region()
      machine = vps(r, node_in(r))
      {:ok, tracked} = Backups.start_backup(machine)

      {:ok, saved} =
        Backups.record_result(tracked.id, %{
          "status" => "done",
          "volid" => "local:backup/x.vma.zst",
          "size_bytes" => "999"
        })

      assert saved.size_bytes == 999
    end

    test "nonsense where a size should be is no size, not a crash" do
      r = region()
      machine = vps(r, node_in(r))
      {:ok, tracked} = Backups.start_backup(machine)

      {:ok, saved} =
        Backups.record_result(tracked.id, %{
          "status" => "done",
          "volid" => "local:backup/x.vma.zst",
          "size_bytes" => "enormous"
        })

      assert is_nil(saved.size_bytes)
    end
  end

  describe "the whole round trip" do
    test "a backup the node reports is recorded with its archive and size" do
      # The agent's report goes through the command-result endpoint, which
      # allow-lists fields. A backup that reports an archive the control plane
      # then drops is a backup nobody can find — which is exactly what happened
      # the first time this ran in production.
      r = region()
      node = node_in(r)
      machine = vps(r, node)

      %{started: 1} = Backups.run_due()

      command =
        Repo.one!(from c in Command, where: c.vps_id == ^machine.id and c.kind == :backup)

      {:ok, _} =
        ControlPlane.Provisioning.apply_result(command, %{
          "status" => "done",
          "vm_id" => machine.provider_vm_id,
          "volid" => "local:backup/vzdump-qemu-106-2026_09_11-23_29_13.vma.zst",
          "size_bytes" => 1_503_729_407
        })

      assert [saved] = Backups.list_for_vps(machine.id)
      assert saved.status == :done
      assert saved.volid == "local:backup/vzdump-qemu-106-2026_09_11-23_29_13.vma.zst"
      assert saved.size_bytes == 1_503_729_407
    end

    test "a backup the node could not take is recorded as failed, VPS untouched" do
      # A failed backup must never make a running VPS look broken.
      r = region()
      machine = vps(r, node_in(r))

      %{started: 1} = Backups.run_due()

      command =
        Repo.one!(from c in Command, where: c.vps_id == ^machine.id and c.kind == :backup)

      {:ok, _} =
        ControlPlane.Provisioning.apply_result(command, %{
          "status" => "failed",
          "error" => "no space left on device"
        })

      assert [%{status: :failed, error: "no space left on device"}] =
               Backups.list_for_vps(machine.id)

      assert Repo.get!(Vps, machine.id).status == :active
    end
  end

  describe "restoring" do
    defp restorable_backup(machine) do
      backup(machine, %{
        status: :done,
        volid: "local:backup/vzdump-qemu-106-2026_09_11.vma.zst",
        started_at: ago(3600),
        finished_at: ago(3500)
      })
    end

    test "a running VPS goes to :restoring and is told to come back running" do
      r = region()
      machine = vps(r, node_in(r))
      point = restorable_backup(machine)

      {:ok, restoring} = Backups.restore(machine, point.id)

      assert restoring.status == :restoring
      assert [command] = commands_for(machine.id, :restore_backup)
      assert command.payload["volid"] == point.volid
      assert command.payload["start_after"] == true
    end

    test "a stopped VPS is left stopped afterwards" do
      r = region()
      machine = vps(r, node_in(r), %{status: :stopped})
      point = restorable_backup(machine)

      {:ok, _} = Backups.restore(machine, point.id)

      assert [command] = commands_for(machine.id, :restore_backup)
      assert command.payload["start_after"] == false
    end

    test "a second restore is refused while the first is running" do
      # Both would tell the node to overwrite the same disk, and the second would
      # land on a machine halfway through being replaced.
      r = region()
      machine = vps(r, node_in(r))
      point = restorable_backup(machine)

      {:ok, restoring} = Backups.restore(machine, point.id)

      assert {:error, {:invalid_status, :restoring}} = Backups.restore(restoring, point.id)
      assert length(commands_for(machine.id, :restore_backup)) == 1
    end

    test "another customer's backup is not found, not forbidden" do
      # Whether some other VPS's backup exists is none of this caller's business.
      r = region()
      node = node_in(r)
      mine = vps(r, node)
      theirs = vps(r, node)
      point = restorable_backup(theirs)

      assert {:error, :not_found} = Backups.restore(mine, point.id)
    end

    test "a failed backup is not a restore point" do
      r = region()
      machine = vps(r, node_in(r))
      point = backup(machine, %{status: :failed, error: "storage full", started_at: ago(3600)})

      assert {:error, :backup_not_restorable} = Backups.restore(machine, point.id)
    end

    test "a backup with no archive behind it is not a restore point" do
      r = region()
      machine = vps(r, node_in(r))
      point = backup(machine, %{status: :done, volid: nil, started_at: ago(3600)})

      assert {:error, :backup_not_restorable} = Backups.restore(machine, point.id)
    end

    test "a VPS that is not up or down cannot be restored onto" do
      r = region()
      machine = vps(r, node_in(r), %{status: :provisioning})
      point = restorable_backup(machine)

      assert {:error, {:invalid_status, :provisioning}} = Backups.restore(machine, point.id)
    end

    test "an unknown backup is not found" do
      r = region()
      machine = vps(r, node_in(r))

      assert {:error, :not_found} = Backups.restore(machine, Ecto.UUID.generate())
    end

    test "a finished restore puts a running VPS back to running" do
      r = region()
      machine = vps(r, node_in(r))
      point = restorable_backup(machine)
      {:ok, _} = Backups.restore(machine, point.id)
      [command] = commands_for(machine.id, :restore_backup)

      {:ok, _} = ControlPlane.Provisioning.apply_result(command, %{"status" => "done"})

      assert Repo.get!(Vps, machine.id).status == :active
    end

    test "a finished restore forgets the pinned SSH host key" do
      # The disk is older, so the guest's host key is older. TOFU would read that
      # as exactly the attack it exists to catch and refuse the console — locking
      # the customer out of what they would use to check the restore worked.
      r = region()
      machine = vps(r, node_in(r))
      {:ok, _} = machine |> Ecto.Changeset.change(ssh_host_key: "SHA256:old") |> Repo.update()
      point = restorable_backup(machine)
      {:ok, _} = Backups.restore(machine, point.id)
      [command] = commands_for(machine.id, :restore_backup)

      {:ok, _} = ControlPlane.Provisioning.apply_result(command, %{"status" => "done"})

      assert is_nil(Repo.get!(Vps, machine.id).ssh_host_key)
    end

    test "a failed restore keeps the pin, because nothing was replaced" do
      r = region()
      machine = vps(r, node_in(r))
      {:ok, _} = machine |> Ecto.Changeset.change(ssh_host_key: "SHA256:old") |> Repo.update()
      point = restorable_backup(machine)
      {:ok, _} = Backups.restore(machine, point.id)
      [command] = commands_for(machine.id, :restore_backup)

      {:ok, _} =
        ControlPlane.Provisioning.apply_result(command, %{
          "status" => "failed",
          "error" => "archive is corrupt"
        })

      assert Repo.get!(Vps, machine.id).ssh_host_key == "SHA256:old"
    end

    test "a failed restore leaves the VPS stopped, not stuck in :restoring" do
      # Stopped rather than active: after a failed qmrestore the disk may be
      # half-written, and starting it automatically is the wrong default. Stuck
      # in :restoring would be worse still — the customer could not touch their
      # own machine over a failure that already happened.
      r = region()
      machine = vps(r, node_in(r))
      point = restorable_backup(machine)
      {:ok, _} = Backups.restore(machine, point.id)
      [command] = commands_for(machine.id, :restore_backup)

      {:ok, _} =
        ControlPlane.Provisioning.apply_result(command, %{
          "status" => "failed",
          "error" => "archive is corrupt"
        })

      assert Repo.get!(Vps, machine.id).status == :stopped
    end
  end

  describe "retention" do
    test "keeps the newest and queues deletion of the rest" do
      r = region()
      machine = vps(r, node_in(r))

      for i <- 1..(Backups.keep() + 2) do
        backup(machine, %{
          status: :done,
          volid: "local:backup/vzdump-#{i}.vma.zst",
          started_at: ago(i * 100),
          finished_at: ago(i * 100 - 10)
        })
      end

      {:ok, pruned} = Backups.prune(machine.id)

      assert pruned == 2
      assert length(commands_for(machine.id, :delete_backup)) == 2
    end

    test "a failed backup is never pruned into a deletion command" do
      # There is no archive to delete, and a deletion command naming nothing
      # would fail on the node forever.
      r = region()
      machine = vps(r, node_in(r))

      for i <- 1..(Backups.keep() + 2) do
        backup(machine, %{status: :failed, error: "nope", started_at: ago(i * 100)})
      end

      assert {:ok, 0} = Backups.prune(machine.id)
      assert [] = commands_for(machine.id, :delete_backup)
    end

    test "the row survives until the node confirms the archive is gone" do
      r = region()
      machine = vps(r, node_in(r))

      kept =
        for i <- 1..(Backups.keep() + 1) do
          backup(machine, %{
            status: :done,
            volid: "local:backup/vzdump-#{i}.vma.zst",
            started_at: ago(i * 100),
            finished_at: ago(i * 100 - 10)
          })
        end

      {:ok, 1} = Backups.prune(machine.id)

      # Still listed: the row is the only handle on a file that still exists.
      assert length(Backups.list_for_vps(machine.id)) == length(kept)

      oldest = List.last(kept)
      {:ok, _} = Backups.forget(oldest.id)
      assert length(Backups.list_for_vps(machine.id)) == length(kept) - 1
    end

    test "forgetting one that is already gone is not an error" do
      assert {:ok, :already_gone} = Backups.forget(Ecto.UUID.generate())
    end
  end

  describe "archieven van verwijderde VPS'en" do
    # `qm destroy` sloopt de gast en zijn schijf en laat de vzdump-archieven
    # staan. Een archief is een volledige kopie van diezelfde schijf, en het
    # verwerkingsregister belooft dat die bij verwijdering vernietigd wordt.
    # Deze tests leggen vast wat er wél en vooral wat er NIET wordt opgeruimd:
    # dit is de enige plek in het systeem die uit zichzelf klantgegevens
    # weggooit, en te ruim is hier erger dan te krap.

    test "het archief van een verwijderde VPS wordt ingepland om te verdwijnen" do
      r = region()
      n = node_in(r)
      weg = vps(r, n, %{status: :deleted})
      backup(weg, %{status: :done, volid: "local:backup/a.vma.zst", finished_at: ago(300)})

      assert {:ok, 1} = Backups.ruim_wees_archieven_op()

      assert [%Command{kind: :delete_backup, payload: %{"volid" => "local:backup/a.vma.zst"}}] =
               commands_for(weg.id, :delete_backup)
    end

    test "het archief van een VPS die nog draait blijft met rust" do
      r = region()
      n = node_in(r)
      levend = vps(r, n)
      backup(levend, %{status: :done, volid: "local:backup/b.vma.zst", finished_at: ago(300)})

      assert {:ok, 0} = Backups.ruim_wees_archieven_op()
      assert [] = commands_for(levend.id, :delete_backup)
    end

    test "twee rondes achter elkaar plannen niet twee keer hetzelfde in" do
      # Zonder deze bescherming staan er na een uur vier commando's voor één
      # bestand, en de bewaker op vastgelopen commando's mailt erover.
      r = region()
      n = node_in(r)
      weg = vps(r, n, %{status: :deleted})
      backup(weg, %{status: :done, volid: "local:backup/c.vma.zst", finished_at: ago(300)})

      assert {:ok, 1} = Backups.ruim_wees_archieven_op()
      assert {:ok, 0} = Backups.ruim_wees_archieven_op()
      assert [_een] = commands_for(weg.id, :delete_backup)
    end

    test "een node die zwijgt krijgt geen opruimwerk" do
      # Het commando zou blijven staan tot hij terugkomt, en intussen meldt de
      # bewaker op vastgelopen commando's het als probleem -- een mail over een
      # machine die gewoon uit staat.
      r = region()
      stil = node_in(r)
      Repo.update!(Ecto.Changeset.change(stil, last_heartbeat_at: ago(3600)))
      weg = vps(r, stil, %{status: :deleted})
      backup(weg, %{status: :done, volid: "local:backup/d.vma.zst", finished_at: ago(300)})

      assert {:ok, 0} = Backups.ruim_wees_archieven_op()
      assert [] = commands_for(weg.id, :delete_backup)
    end

    test "een back-up zonder archief valt er niet onder" do
      # Een mislukte of nog lopende back-up heeft geen bestand op de node. Een
      # verwijderopdracht sturen voor niets levert een commando op dat nergens
      # over gaat.
      r = region()
      n = node_in(r)
      weg = vps(r, n, %{status: :deleted})
      backup(weg, %{status: :failed, error: "vzdump viel om", finished_at: ago(300)})

      assert {:ok, 0} = Backups.ruim_wees_archieven_op()
      assert [] = commands_for(weg.id, :delete_backup)
    end

    test "de ronde is begrensd" do
      r = region()
      n = node_in(r)
      weg = vps(r, n, %{status: :deleted})

      for i <- 1..5 do
        backup(weg, %{
          status: :done,
          volid: "local:backup/veel-#{i}.vma.zst",
          finished_at: ago(300 + i)
        })
      end

      assert {:ok, 2} = Backups.ruim_wees_archieven_op(2)
      assert length(commands_for(weg.id, :delete_backup)) == 2
    end
  end
end
