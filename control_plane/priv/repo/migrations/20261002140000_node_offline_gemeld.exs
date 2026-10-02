defmodule ControlPlane.Repo.Migrations.NodeOfflineGemeld do
  use Ecto.Migration

  # Een node die wegvalt werd tot nu toe alleen omgezet naar `:offline` en
  # doorgegeven aan open dashboards. Er ging nergens een melding naar een
  # operator, dus een node kon acht dagen stil liggen zonder dat iemand het hoorde
  # -- en dat is gebeurd.
  #
  # Dit onthoudt dat er voor deze uitval al gemeld is, zodat het bij één mail per
  # uitval blijft. Het is dezelfde constructie als `stuck_notified_at` op
  # commando's, en hij gaat terug naar NULL zodra de node weer een hartslag geeft:
  # de volgende uitval is een nieuwe gebeurtenis.
  #
  # NULL is hier "nog niet gemeld", ook voor bestaande rijen. Een node die nu al
  # offline staat krijgt dus bij de eerstvolgende ronde één melding -- en dat is
  # precies wat er voor Maastricht had moeten gebeuren.
  def change do
    alter table(:nodes) do
      add :offline_notified_at, :utc_datetime
    end
  end
end
