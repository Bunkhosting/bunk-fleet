defmodule ControlPlane.Repo.Migrations.BeheerAudit do
  use Ecto.Migration

  # Wie welke beheerhandeling deed, in de database in plaats van alleen in de
  # applicatielog. De log is te wissen door wie de container kan lezen, bevatte
  # geen bedragen of rollen, en de API met het gedeelde geheim (/admin/v1) liet
  # helemaal geen spoor na -- ook niet bij het bijboeken van tegoed.
  #
  # Alleen toevoegen. De trigger weigert UPDATE en DELETE. Wie de database
  # beheert kan hem weghalen, maar dan is dat een bewuste daad en geen
  # update_all die per ongeluk een spoor overschrijft.
  def up do
    create table(:beheer_audit, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Een momentopname: de beheerder kan later verwijderd worden, het spoor
      # niet.
      add :actor, :string, null: false
      add :methode, :string, null: false
      add :pad, :string, null: false
      add :uitkomst, :integer
      add :ip, :string
      add :details, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:beheer_audit, [:inserted_at])

    execute("""
    CREATE FUNCTION beheer_audit_alleen_toevoegen() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'beheer_audit is alleen-toevoegen';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER beheer_audit_alleen_toevoegen
    BEFORE UPDATE OR DELETE ON beheer_audit
    FOR EACH ROW EXECUTE FUNCTION beheer_audit_alleen_toevoegen()
    """)
  end

  def down do
    execute("DROP TRIGGER beheer_audit_alleen_toevoegen ON beheer_audit")
    execute("DROP FUNCTION beheer_audit_alleen_toevoegen()")
    drop table(:beheer_audit)
  end
end
