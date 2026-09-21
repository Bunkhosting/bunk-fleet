defmodule ControlPlane.BackupGelijktijdigTest do
  @moduledoc """
  Eén lopende back-up per VPS, en geen back-up die eeuwig "bezig" blijft.

  Drie gelijktijdige verzoeken leverden op productie drie back-ups op: de
  controle keek eerst en schreef daarna. Een back-up is een volledige vzdump, dus
  dat is drie keer het schijf- en I/O-werk op de machine van een operator.

  Het slot daarop maakt een tweede fout ineens gevaarlijk: er stond een back-up
  sinds twee dagen op `:running` omdat de node nooit terugmeldde, en met een slot
  zou zo'n rij élke volgende back-up van die VPS tegenhouden. Een vangnet dat een
  dienst blokkeert is erger dan geen vangnet -- vandaar dat beide hier samen
  getest worden.
  """
  use ControlPlane.DataCase, async: false

  import Ecto.Query

  alias ControlPlane.Backups
  alias ControlPlane.Backups.VpsBackup
  alias ControlPlane.Clock
  alias ControlPlane.Fleet.Node
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  defp draaiende_vps do
    region =
      %Region{}
      |> Region.changeset(%{code: "r-#{System.unique_integer([:positive])}", name: "Regio"})
      |> Repo.insert!()

    node =
      %Node{}
      |> Node.changeset(%{
        name: "node-#{System.unique_integer([:positive])}",
        region_id: region.id
      })
      |> Ecto.Changeset.change(%{status: :online, last_heartbeat_at: Clock.now()})
      |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "backuptest",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20,
      owner_email: "klant@voorbeeld.nl"
    })
    |> Ecto.Changeset.change(%{status: :active, node_id: node.id, provider_vm_id: "901"})
    |> Repo.insert!()
  end

  defp lopend(vps),
    do:
      Repo.one(
        from b in VpsBackup,
          where: b.vps_id == ^vps.id and b.status == :running,
          select: count(b.id)
      )

  test "een tweede verzoek krijgt te horen dat er al een loopt" do
    vps = draaiende_vps()

    assert {:ok, %VpsBackup{}} = Backups.start_on_demand(vps)
    assert {:error, :already_running} = Backups.start_on_demand(vps)
    assert lopend(vps) == 1
  end

  test "de database laat er maar één door, ook als de voorwacht wordt overgeslagen" do
    vps = draaiende_vps()
    assert {:ok, _} = Backups.start_on_demand(vps)

    # Rechtstreeks starten, zoals een gelijktijdig verzoek doet dat de controle
    # al voorbij was. Zonder de index zou dit gewoon lukken.
    assert {:error, :already_running} = Backups.start_backup(vps)
    assert lopend(vps) == 1
  end

  test "een back-up die blijft hangen wordt opgeruimd en blokkeert de volgende niet" do
    vps = draaiende_vps()
    assert {:ok, backup} = Backups.start_on_demand(vps)

    # Zeven uur geleden gestart en nooit iets van gehoord.
    lang_geleden = Clock.shift(-7 * 3600)

    Repo.update_all(from(b in VpsBackup, where: b.id == ^backup.id),
      set: [started_at: lang_geleden]
    )

    assert {1, _} = Backups.fail_vastgelopen()
    opgeruimd = Repo.get!(VpsBackup, backup.id)
    assert opgeruimd.status == :failed
    assert opgeruimd.error =~ "niets terug"

    # En daarna kan er gewoon weer een.
    assert {:ok, %VpsBackup{}} = Backups.start_on_demand(vps)
  end

  test "een back-up die net loopt wordt met rust gelaten" do
    vps = draaiende_vps()
    assert {:ok, _} = Backups.start_on_demand(vps)
    assert {0, _} = Backups.fail_vastgelopen()
    assert lopend(vps) == 1
  end
end
