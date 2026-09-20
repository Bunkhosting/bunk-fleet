defmodule ControlPlane.Accounts.Testaccount do
  @moduledoc """
  Maakt een bevestigd account aan zonder de weg via de browser.

  Registreren gaat normaal langs Turnstile en een bevestigingsmail, en dat hoort
  zo: zonder die twee farmt een bot gratis welkomstkrediet. Maar het betekent
  ook dat alles achter het inlogscherm -- het dashboard, de console, back-ups,
  facturatie, de tweede factor -- niet te testen is zonder een mens met een
  browser en een mailbox. Dat gat is groter dan het lijkt: het is precies de
  helft van het product waar een klant zijn tijd doorbrengt.

  ## Waarom dit geen endpoint is

  Deze functie slaat de captcha over. Als hij over het net bereikbaar zou zijn,
  met welk token dan ook, was dat een tweede deur naast de voordeur -- en de
  voordeur staat er juist om accounts tegen te houden. Nu vraagt het een shell
  op de machine waar de database al op staat, en wie die heeft kan sowieso alles.

  ## Wat het niet doet

  Geen beheerder maken. Een testaccount is een klant, en een test die als
  beheerder draait test iets anders dan wat een klant ziet.
  """
  import Ecto.Query

  alias ControlPlane.Accounts.User
  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Repo

  @doc """
  Maakt `email` aan met `wachtwoord`, meteen bevestigd en mét welkomstkrediet.

  Geeft `{:error, :bestaat_al}` als het adres al in gebruik is -- ook dat is een
  antwoord, en beter dan een tweede account naast het eerste.
  """
  @spec maak(String.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def maak(email, wachtwoord) when is_binary(email) and is_binary(wachtwoord) do
    genormaliseerd = email |> String.trim() |> String.downcase()

    if bestaat?(genormaliseerd) do
      {:error, :bestaat_al}
    else
      aanmaken(genormaliseerd, wachtwoord)
    end
  end

  defp aanmaken(email, wachtwoord) do
    # Dezelfde changeset als een echte registratie: dezelfde eisen aan het
    # wachtwoord, dezelfde hash. Een testaccount dat op een andere manier is
    # opgebouwd dan een klantaccount test niet wat een klant meemaakt.
    #
    # Wat hier NIET gebeurt is de bevestigingsmail versturen. Het adres van een
    # testaccount hoort nergens te bestaan; een mail erheen levert alleen een
    # bounce op bij de mailprovider.
    changeset =
      %User{}
      |> User.registration_changeset(%{
        "email" => email,
        "password" => wachtwoord,
        "name" => "Testaccount"
      })
      |> Ecto.Changeset.put_change(:confirmed_at, Clock.now())

    with {:ok, user} <- Repo.insert(changeset),
         {:ok, _} <- Credits.grant_signup_bonus(user.id) do
      {:ok, user}
    end
  end

  defp bestaat?(email) do
    Repo.exists?(from u in User, where: fragment("lower(?)", u.email) == ^email)
  end
end
