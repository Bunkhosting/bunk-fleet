defmodule ControlPlane.Repo.Migrations.VastgelopenCommandoEenmaalMelden do
  use Ecto.Migration

  # De melding over vastgelopen commando's vuurde elke reconcilertik opnieuw.
  # De doorstuurbeperking maakte er drie mails per uur van -- dag en nacht,
  # zolang de toestand bestond. In 24 uur leverde dat 88 foutregels en een
  # postvak vol op voor drie commando's die één keer bekeken hadden moeten
  # worden.
  #
  # Dat is de fout die je maakt als je "niet stil falen" doorschiet naar "blijf
  # schreeuwen". Een toestand die blijft bestaan hoort één melding te geven, niet
  # een stroom: na de eerste weet de lezer het, en elke volgende maakt alleen de
  # kans kleiner dat hij de volgende écht leest.
  def change do
    alter table(:commands) do
      add :stuck_notified_at, :utc_datetime
    end
  end
end
