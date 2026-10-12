defmodule ControlPlane.Accounts.Deletion do
  @moduledoc """
  Een account verwijderen, of anonimiseren als er een administratie aan hangt.

  `delete_or_anonymise_user/1` kiest tussen weigeren (er draait nog een VPS),
  anonimiseren (er is geld aan te pas gekomen, dus de bedragen moeten blijven)
  en echt verwijderen (er valt niets te bewaren). De controles waarop die
  keuze rust, `has_live_vpses?/1` en `has_financial_history?/1`, zijn ook los
  te gebruiken, net als `owns_nodes?/1`.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Accounts.Passkey
  alias ControlPlane.Accounts.User
  alias ControlPlane.Accounts.UserToken
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Credits.TopupRequest
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  @doc """
  Verwijdert een account, of anonimiseert het als er een administratie aan hangt.

  Drie uitkomsten, en het verschil is niet cosmetisch.

  `{:error, :has_vpses}` zolang er nog een levende VPS van deze gebruiker is.
  De sleutelregel op `vpses.owner_id` is `nilify`, dus zonder deze weigering
  blijft er een draaiende machine over zonder eigenaar: hij eet capaciteit,
  niemand betaalt ervoor, en niemand kan er via het dashboard nog bij. Eerst
  opruimen, dan pas het account.

  `{:ok, :anonymised}` zodra er geld aan te pas is gekomen. De sleutelregels op
  `topup_requests` en `ledger_entries` zijn `delete_all`, dus echt verwijderen
  neemt de facturen en het grootboek mee -- precies de administratie waarop de
  btw-aangifte rust en die zeven jaar bewaard moet blijven. De omzet over een
  afgesloten kwartaal zou met terugwerkende kracht veranderen. In plaats daarvan
  gaan de persoonsgegevens eruit en blijven de bedragen staan. Dat is wat de AVG
  met het recht op vergetelheid bedoelt én wat de Belastingdienst wil.

  `{:ok, :deleted}` als er nooit iets financieels is geweest. Dan valt er niets
  te bewaren en is echt verwijderen het eerlijkste antwoord.
  """
  @spec delete_or_anonymise_user(User.t()) ::
          {:ok, :deleted | :anonymised} | {:error, :has_vpses | Ecto.Changeset.t()}
  def delete_or_anonymise_user(%User{} = user) do
    cond do
      has_live_vpses?(user) -> {:error, :has_vpses}
      has_financial_history?(user) -> anonymise_user(user)
      true -> hard_delete_user(user)
    end
  end

  @doc "Of er nog een levende VPS van deze gebruiker is."
  @spec has_live_vpses?(User.t()) :: boolean()
  def has_live_vpses?(%User{id: id}) do
    Repo.exists?(
      from v in Vps,
        where: v.owner_id == ^id and v.status not in [:deleted, :failed]
    )
  end

  @doc "Of er iets aan deze gebruiker hangt dat bewaard moet blijven."
  @spec has_financial_history?(User.t()) :: boolean()
  def has_financial_history?(%User{id: id}) do
    Repo.exists?(from t in TopupRequest, where: t.user_id == ^id) or
      Repo.exists?(from l in LedgerEntry, where: l.user_id == ^id)
  end

  @doc """
  Of deze gebruiker hardware beheert.

  Bewust een bestaanscheck en geen telling: het dashboard wil alleen weten of het
  het nodescherm moet tonen, en `exists?` stopt bij de eerste rij.
  """
  @spec owns_nodes?(User.t()) :: boolean()
  def owns_nodes?(%User{id: id}) do
    Repo.exists?(from n in ControlPlane.Fleet.Node, where: n.owner_id == ^id)
  end

  defp anonymise_user(%User{id: id} = user) do
    # Het adres moet uniek blijven en herkenbaar als verwijderd. De id erin maakt
    # hem uniek zonder dat er iets van de persoon in achterblijft.
    vervangend = "verwijderd-#{String.replace(id, "-", "")}@verwijderd.invalid"

    user
    |> Ecto.Changeset.change(%{
      email: vervangend,
      name: nil,
      # Een wachtwoordhash die nergens bij hoort: inloggen kan niet meer, en er
      # blijft geen bruikbaar geheim staan.
      hashed_password: Pbkdf2.hash_pwd_salt(Base.encode64(:crypto.strong_rand_bytes(32))),
      totp_secret: nil,
      totp_confirmed_at: nil,
      confirmed_at: nil,
      role: :user,
      anonymised_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
    |> case do
      {:ok, _} ->
        # Sessies en passkeys gaan mee: een geanonimiseerd account hoort nergens
        # meer binnen te kunnen.
        Repo.delete_all(from t in UserToken, where: t.user_id == ^id)
        Repo.delete_all(from p in Passkey, where: p.user_id == ^id)

        # En het adres dat buiten de users-tabel is blijven staan. `vpses`
        # bewaart het als los label naast `owner_id`, en dat label overleefde
        # het anonimiseren -- waarmee "verwijderd" in het beheerscherm stond
        # terwijl het adres er in de VPS-lijst gewoon nog bij hing.
        #
        # Alleen `vpses`: `nodes`, `enroll_tokens` en `usage_records` dragen het
        # adres van een node-EIGENAAR, en dat is een andere betrokkene met een
        # eigen account. Die meenemen zou het adres van iemand anders wissen.
        Repo.update_all(
          from(v in Vps, where: v.owner_id == ^id),
          set: [owner_email: vervangend]
        )

        {:ok, :anonymised}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp hard_delete_user(%User{id: id} = user) do
    # Eerst het losse label, dán de rij. Andersom is te laat: zodra de gebruiker
    # weg is wordt `owner_id` op de VPS'en genilificeerd en is niet meer te
    # bepalen welke rijen van hem waren -- het adres blijft dan staan op een VPS
    # die niemand meer kan koppelen, wat slechter is dan waar we begonnen.
    Repo.update_all(from(v in Vps, where: v.owner_id == ^id), set: [owner_email: nil])

    case Repo.delete(user) do
      {:ok, _} -> {:ok, :deleted}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
