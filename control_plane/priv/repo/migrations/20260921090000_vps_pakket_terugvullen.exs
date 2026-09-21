defmodule ControlPlane.Repo.Migrations.VpsPakketTerugvullen do
  use Ecto.Migration

  # `vpses.package_id` is nooit gevuld: de insert liet het veld vallen. Elke VPS
  # die ooit is besteld staat daardoor zonder pakket in de database.
  #
  # Terugvullen kan zonder te gokken, want het abonnement weet het wél --
  # `Subscriptions.create_for_vps/3` kreeg dezelfde package_id mee en bewaarde
  # hem correct. Dat is een vastgelegd feit uit het moment van bestellen, geen
  # afleiding uit de specificaties achteraf. Dat laatste zou wél gokken zijn:
  # twee pakketten kunnen dezelfde specs hebben, en een pakket dat uit de
  # catalogus is gehaald zou een ander pakket toegewezen krijgen.
  #
  # Alleen waar het veld leeg is, en alleen waar er precies één abonnement bij
  # hoort.
  def up do
    execute("""
    UPDATE vpses v
       SET package_id = s.package_id
      FROM (
        SELECT DISTINCT ON (vps_id) vps_id, package_id
          FROM subscriptions
         WHERE package_id IS NOT NULL
         ORDER BY vps_id, inserted_at ASC
      ) s
     WHERE s.vps_id = v.id
       AND v.package_id IS NULL
    """)
  end

  # Niet terugdraaien. De kolom leegmaken zou de gegevens weggooien die deze
  # migratie juist herstelt, en het oude gedrag was een bug.
  def down, do: :ok
end
