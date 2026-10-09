defmodule ControlPlane.Repo.Migrations.SessieTweedeFactor do
  use Ecto.Migration

  # Wanneer deze sessie haar tweede factor liet zien. NULL = nooit.
  #
  # Het beheerpaneel keek of het ACCOUNT een tweede factor had, niet of de
  # SESSIE er een had laten zien. Wie het wachtwoord van een beheerder zonder
  # 2FA had, logde in met alleen dat wachtwoord, zette in diezelfde sessie zijn
  # eigen authenticator aan, en stond in het paneel.
  #
  # NULL voor alle bestaande sessies is hier precies de bedoeling, en geen
  # toevallige terugwerkende kracht: van geen enkele bestaande sessie weten we of
  # er een tweede factor bij was. Beheerders loggen één keer opnieuw in; voor
  # klanten verandert er niets, want alleen het beheerpaneel kijkt hiernaar.
  def change do
    alter table(:user_tokens) do
      add :mfa_at, :utc_datetime
    end
  end
end
