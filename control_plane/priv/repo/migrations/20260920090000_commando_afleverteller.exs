defmodule ControlPlane.Repo.Migrations.CommandoAfleverteller do
  use Ecto.Migration

  # Een commando dat na 90 seconden geen resultaat heeft opgeleverd, wordt
  # opnieuw uitgedeeld. Dat is goed: een agent die halverwege omvalt hoort zijn
  # werk terug te krijgen, en de agent is idempotent.
  #
  # Maar er zat geen bovengrens op. Faalt niet het werk maar het terugmelden --
  # de POST met het resultaat sneuvelt op een proxy of op een herstart van het
  # control plane -- dan herhaalt dit zich elke 90 seconden, eeuwig. De VPS staat
  # bij de klant in "aanmaken" terwijl hij op de node al draait, en er is niets
  # dat dat zegt.
  #
  # Tellen is de helft van de oplossing; de andere helft is dat iemand het hoort.
  def change do
    alter table(:commands) do
      add :delivery_count, :integer, null: false, default: 0
    end
  end
end
