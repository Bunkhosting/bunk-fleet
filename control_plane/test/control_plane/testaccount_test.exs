defmodule ControlPlane.TestaccountTest do
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.Testaccount
  alias ControlPlane.Credits

  @wachtwoord "een-voldoende-lang-testwachtwoord"

  test "het account is meteen bruikbaar: bevestigd, met krediet, en je kunt ermee inloggen" do
    assert {:ok, user} = Testaccount.maak("Test@bunkhosting.nl", @wachtwoord)

    # Kleingeschreven opgeslagen, zodat inloggen met hoofdletters ook werkt.
    assert user.email == "test@bunkhosting.nl"
    refute is_nil(user.confirmed_at)
    assert Credits.balance_cents(user.id) == Credits.signup_bonus_cents()

    # De hele reden dat dit bestaat: hiermee komt een test achter het inlogscherm.
    assert %{id: id} = Accounts.get_user_by_email_and_password("test@bunkhosting.nl", @wachtwoord)
    assert id == user.id
  end

  test "een tweede keer hetzelfde adres levert geen tweede account op" do
    assert {:ok, _} = Testaccount.maak("dubbel@bunkhosting.nl", @wachtwoord)
    assert {:error, :bestaat_al} = Testaccount.maak("  DUBBEL@bunkhosting.nl ", @wachtwoord)
  end

  test "de eisen aan het wachtwoord gelden ook hier" do
    assert {:error, %Ecto.Changeset{}} = Testaccount.maak("kort@bunkhosting.nl", "kort")
  end

  test "een testaccount is een klant en geen beheerder" do
    assert {:ok, user} = Testaccount.maak("rol@bunkhosting.nl", @wachtwoord)
    assert user.role == :user
  end
end
