defmodule ControlPlane.Repo.Migrations.EenMachtscommandoTegelijk do
  use Ecto.Migration

  # `in_flight?/2` keek of er al een start/stop/reboot onderweg was en sloeg het
  # inplannen dan over. Dat werkt tegen een dubbelklik -- de eerste klik heeft
  # dan al ingevoegd -- maar niet tegen echte gelijktijdigheid: tien verzoeken
  # tegelijk lezen alle tien "er loopt niets" voordat er één invoegt.
  #
  # Gemeten op productie met tien gelijktijdige herstarts: tien commando's
  # aangemaakt, één afgerond, zes geweigerd door de agent en drie voorgoed
  # blijven hangen. Kijken-dan-schrijven is geen slot; de database is dat wel.
  #
  # De index kan er niet zomaar op, en dat weet ik omdat deze migratie in haar
  # eerste vorm de uitrol liet klappen: die drie blijvende reboots stonden er nog
  # en botsten meteen. Een unieke index op bestaande gegevens is niet alleen een
  # regel voor de toekomst maar ook een uitspraak over het verleden. Dus eerst
  # opruimen wat niet meer kan lopen, dan pas het slot.
  #
  # De oudste blijft staan: die is als eerste uitgedeeld en is degene waar de
  # agent mogelijk nog mee bezig is. De jongere duplicaten hadden nooit mogen
  # bestaan.
  def up do
    execute("""
    UPDATE commands c
       SET status = 'failed',
           result = COALESCE(c.result, '{}'::jsonb) ||
                    '{"error":"er stond al een gelijksoortig commando voor deze VPS"}'::jsonb,
           updated_at = now()
     WHERE c.status IN ('pending','delivered')
       AND c.kind IN ('start','stop','reboot','pause','resume')
       AND c.vps_id IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM commands o
          WHERE o.vps_id = c.vps_id
            AND o.kind = c.kind
            AND o.status IN ('pending','delivered')
            AND (o.inserted_at < c.inserted_at
                 OR (o.inserted_at = c.inserted_at AND o.id < c.id))
       )
    """)

    create unique_index(
             :commands,
             [:vps_id, :kind],
             where:
               "status IN ('pending','delivered') AND kind IN ('start','stop','reboot','pause','resume')",
             name: :commands_een_machtscommando_per_vps_uidx
           )
  end

  def down do
    drop index(:commands, [:vps_id, :kind], name: :commands_een_machtscommando_per_vps_uidx)
  end
end
