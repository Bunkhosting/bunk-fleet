defmodule ControlPlane.Repo.Migrations.LedgerVpsRestrict do
  use Ecto.Migration

  # Was nilify_all. Een VPS-rij die ooit hard verwijderd werd, maakte van al
  # zijn afschrijvingen regels zonder vps_id -- en precies die betaalt
  # `Credits.refund_orphan_charges/1` terug als "de VPS is nooit aangemaakt".
  # VPS-rijen worden nooit hard verwijderd (status :deleted), dus restrict kost
  # niets en maakt van die stille terugbetaling een luide fout.
  def change do
    alter table(:ledger_entries) do
      modify :vps_id, references(:vpses, type: :binary_id, on_delete: :restrict),
        from: references(:vpses, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
