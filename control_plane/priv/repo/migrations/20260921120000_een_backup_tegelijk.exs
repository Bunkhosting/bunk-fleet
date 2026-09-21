defmodule ControlPlane.Repo.Migrations.EenBackupTegelijk do
  use Ecto.Migration

  # Dezelfde vorm als bij de machtscommando's: `loopt_er_al_een?/1` kijkt of er
  # een back-up draait en slaat het starten dan over. Tegen een dubbelklik werkt
  # dat; tegen drie gelijktijdige verzoeken niet -- die lezen alle drie "er
  # loopt niets" voordat er één invoegt. Gemeten op productie: drie verzoeken
  # leverden drie back-ups op, en een back-up is een volledige vzdump op de
  # machine van een operator.
  #
  # De index kan er niet zomaar op. Er stonden bij het schrijven van deze
  # migratie drie back-ups op `:running`, waarvan één sinds twee dagen -- de
  # node meldde nooit terug en er is niets dat zoiets opruimt. De index zou
  # daarop stuklopen, en waar hij het wel haalde zou zo'n blijvende rij élke
  # volgende back-up van die VPS tegenhouden. Vandaar de volgorde: eerst
  # opruimen wat niet meer loopt, dan pas het slot erop.
  def up do
    # 1. Wat langer dan zes uur "bezig" is, loopt niet meer.
    execute("""
    UPDATE vps_backups
       SET status = 'failed',
           error = 'de node meldde niets terug binnen 6 uur',
           finished_at = now(),
           updated_at = now()
     WHERE status = 'running'
       AND started_at IS NOT NULL
       AND started_at < now() - interval '6 hours'
    """)

    # 2. Blijven er per VPS meerdere over, dan is de nieuwste de echte: die is
    #    als laatste gestart en heeft de meeste kans nog te lopen.
    execute("""
    UPDATE vps_backups b
       SET status = 'failed',
           error = 'er liep al een back-up voor deze VPS',
           finished_at = now(),
           updated_at = now()
     WHERE b.status = 'running'
       AND EXISTS (
         SELECT 1 FROM vps_backups n
          WHERE n.vps_id = b.vps_id
            AND n.status = 'running'
            AND (n.started_at > b.started_at
                 OR (n.started_at = b.started_at AND n.id > b.id))
       )
    """)

    create unique_index(:vps_backups, [:vps_id],
             where: "status = 'running'",
             name: :vps_backups_een_lopende_per_vps_uidx
           )
  end

  def down do
    drop index(:vps_backups, [:vps_id], name: :vps_backups_een_lopende_per_vps_uidx)
  end
end
