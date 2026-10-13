defmodule ControlPlane.Repo.Migrations.VpsRegioLosBijVerwijderen do
  use Ecto.Migration

  @moduledoc """
  Een verwijderde locatie laat de VPS'en die er ooit draaiden achter zonder
  locatie, in plaats van zichzelf onverwijderbaar te maken.

  `vpses.region_id` was NOT NULL met `on_delete: :restrict`. Dat betekende: een
  locatie waar ooit een VPS in heeft gedraaid kon nooit meer weg, ook niet als
  die VPS allang verwijderd was en er geen node meer in stond. In de praktijk is
  dat elke locatie die ooit gebruikt is -- en dus bleef een typefout of een
  afgebouwde locatie voor altijd in het beheerscherm staan.

  De afweging. Wat verdwijnt is het label "deze verwijderde machine draaide in
  Landhorst". Wat blijft is alles waar de administratie aan hangt: het
  grootboek, de abonnementen en het verbruik verwijzen naar de VPS en niet naar
  de regio. Een locatie mag pas weg als er geen node meer in staat en geen enkele
  VPS er nog in draait -- zie `Fleet.Regions.delete_region/1` -- dus dit raakt alleen
  geschiedenis van machines die er niet meer zijn.

  De kolom blijft verplicht in de changeset: een nieuwe VPS zonder locatie
  bestaat niet. Alleen de database laat leeg toe, en alleen omdat het opruimen
  van de locatie dat veroorzaakt.
  """
  def up do
    execute "ALTER TABLE vpses DROP CONSTRAINT IF EXISTS vpses_region_id_fkey"
    execute "ALTER TABLE vpses ALTER COLUMN region_id DROP NOT NULL"

    execute """
    ALTER TABLE vpses
      ADD CONSTRAINT vpses_region_id_fkey
      FOREIGN KEY (region_id) REFERENCES regions(id) ON DELETE SET NULL
    """
  end

  def down do
    execute "ALTER TABLE vpses DROP CONSTRAINT IF EXISTS vpses_region_id_fkey"

    # Terug naar NOT NULL kan alleen als er geen lege waarden staan. Die zijn er
    # zodra er ooit een locatie is opgeruimd, dus deze weg terug is niet gratis
    # en dat hoort hier te staan in plaats van dat iemand het ontdekt.
    execute """
    ALTER TABLE vpses
      ADD CONSTRAINT vpses_region_id_fkey
      FOREIGN KEY (region_id) REFERENCES regions(id) ON DELETE RESTRICT
    """
  end
end
