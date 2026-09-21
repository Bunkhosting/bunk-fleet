defmodule ControlPlane.Repo.Migrations.EenMachtscommandoTegelijk do
  use Ecto.Migration

  # `in_flight?/2` keek of er al een start/stop/reboot onderweg was en sloeg het
  # inplannen dan over. Dat werkt tegen een dubbelklik -- de eerste klik heeft
  # dan al ingevoegd -- maar niet tegen echte gelijktijdigheid: tien verzoeken
  # tegelijk lezen alle tien "er loopt niets" voordat er één invoegt.
  #
  # Gemeten op productie met tien gelijktijdige herstarts: tien commando's
  # aangemaakt, één afgerond, zes geweigerd door de agent en drie voorgoed
  # blijven hangen in herlevering. Kijken-dan-schrijven is geen slot; de
  # database is dat wel.
  #
  # Alleen voor de machtscommando's. Een provision of een backup mag wel
  # meerdere keren in de rij staan -- die gaan over verschillende dingen.
  def change do
    create unique_index(
             :commands,
             [:vps_id, :kind],
             where:
               "status IN ('pending','delivered') AND kind IN ('start','stop','reboot','pause','resume')",
             name: :commands_een_machtscommando_per_vps_uidx
           )
  end
end
