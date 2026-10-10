defmodule ControlPlane.AccountsDeleteUserTest do
  @moduledoc """
  Een account verwijderen is drie verschillende dingen, afhankelijk van wat eraan
  hangt. De sleutelregels in de database maken van een naïeve `Repo.delete` een
  dure fout: `topup_requests` en `ledger_entries` staan op `delete_all`, dus de
  facturen en het grootboek gaan mee — de administratie waarop de btw-aangifte
  rust en die zeven jaar bewaard moet blijven. En `vpses.owner_id` staat op
  `nilify`, dus een draaiende machine blijft over zonder eigenaar.
  """
  use ControlPlane.DataCase, async: true

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.User
  alias ControlPlane.Credits
  alias ControlPlane.Credits.LedgerEntry
  alias ControlPlane.Fleet.Region
  alias ControlPlane.Fleet.Vps
  alias ControlPlane.Repo

  defp gebruiker(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: "Str0ngPassphrase!42"})
    # De aanmeldbonus is een grootboekregel, en die zou elke gebruiker meteen
    # "financiële geschiedenis" geven. Voor deze tests beginnen we schoon.
    Repo.delete_all(from l in LedgerEntry, where: l.user_id == ^u.id)
    u
  end

  defp vps_van(user, status) do
    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    %Vps{}
    |> Vps.changeset(%{
      name: "vps-#{System.unique_integer([:positive])}",
      region_id: region.id,
      vcpu: 1,
      ram_mb: 1024,
      disk_gb: 20
    })
    |> Ecto.Changeset.change(%{owner_id: user.id, status: status})
    |> Repo.insert!()
  end

  describe "een account zonder geschiedenis" do
    test "wordt echt verwijderd" do
      u = gebruiker("leeg@bunk.test")

      assert {:ok, :deleted} = Accounts.delete_or_anonymise_user(u)
      assert is_nil(Repo.get(User, u.id))
    end

    test "een gewoon account is niet als verwijderd gemarkeerd" do
      # De keerzijde: zonder deze test zou "alles als verwijderd tonen" ook slagen.
      u = gebruiker("gewoon@bunk.test")

      assert is_nil(Repo.get!(User, u.id).anonymised_at)
    end
  end

  describe "een account met een administratie" do
    test "wordt geanonimiseerd, en de bedragen blijven staan" do
      u = gebruiker("betaald@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 5000, "topup", "test")

      assert {:ok, :anonymised} = Accounts.delete_or_anonymise_user(u)

      bewaard = Repo.get!(User, u.id)
      refute bewaard.email == "betaald@bunk.test"
      assert bewaard.email =~ "@verwijderd.invalid"
      assert is_nil(bewaard.name)

      # Dit is waar het om gaat: de administratie is intact.
      assert Repo.aggregate(from(l in LedgerEntry, where: l.user_id == ^u.id), :count) == 1

      # En het is als verwijderd herkenbaar, niet alleen aan de vorm van het
      # adres: het scherm moet zo'n rij kunnen tonen als wat hij is, want anders
      # lijkt verwijderen mislukt.
      refute is_nil(bewaard.anonymised_at)
    end

    test "kan daarna niet meer inloggen" do
      u = gebruiker("betaald2@bunk.test")
      {:ok, _} = Credits.add_entry(u.id, 1000, "topup", "test")
      _token = Accounts.generate_user_session_token(u)

      assert {:ok, :anonymised} = Accounts.delete_or_anonymise_user(u)

      assert is_nil(
               Accounts.get_user_by_email_and_password(
                 "betaald2@bunk.test",
                 "Str0ngPassphrase!42"
               )
             )

      assert Repo.aggregate(
               from(t in ControlPlane.Accounts.UserToken, where: t.user_id == ^u.id),
               :count
             ) == 0
    end

    test "verliest zijn beheerdersrol" do
      # Anders blijft er een geanonimiseerd account met adminrechten staan.
      u = gebruiker("betaald3@bunk.test")
      {:ok, u} = Accounts.update_user_role(u, :admin)
      {:ok, _} = Credits.add_entry(u.id, 1000, "topup", "test")

      assert {:ok, :anonymised} = Accounts.delete_or_anonymise_user(u)
      assert Repo.get!(User, u.id).role == :user
    end
  end

  describe "een account met een draaiende VPS" do
    test "wordt geweigerd" do
      # Zonder deze weigering blijft er een machine draaien die niemand bezit,
      # waar niemand voor betaalt en waar niemand meer bij kan.
      u = gebruiker("draait@bunk.test")
      vps_van(u, :active)

      assert {:error, :has_vpses} = Accounts.delete_or_anonymise_user(u)
      assert Repo.get!(User, u.id).email == "draait@bunk.test"
    end

    test "een verwijderde of mislukte VPS houdt niets tegen" do
      u = gebruiker("opgeruimd@bunk.test")
      vps_van(u, :deleted)
      vps_van(u, :failed)

      assert {:ok, :deleted} = Accounts.delete_or_anonymise_user(u)
    end
  end

  test "het adres verdwijnt ook uit de VPS-lijst" do
    # Het stond op twee plekken: in `users` en als los label op elke VPS. Alleen
    # de eerste wissen liet "verwijderd" in het beheerscherm zien terwijl het
    # adres er in de VPS-lijst gewoon nog bij hing.
    {:ok, user} =
      Accounts.register_user(%{
        email: "label-#{System.unique_integer([:positive])}@bunk.test",
        password: "Str0ngPassphrase!42"
      })

    code = "r-#{System.unique_integer([:positive])}"

    region =
      %Region{}
      |> Region.changeset(%{code: code, name: "Regio"})
      |> Repo.insert!()

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "machine",
        region_id: region.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20,
        owner_email: user.email
      })
      |> Ecto.Changeset.change(%{owner_id: user.id, status: :deleted})
      |> Repo.insert!()

    # Deze gebruiker heeft financiële geschiedenis, dus hij wordt geanonimiseerd
    # en niet verwijderd -- dat is het pad waarop het label bleef staan.
    {:ok, _} = Credits.add_entry(user.id, 500, "admin_adjustment", "geschiedenis")
    {:ok, :anonymised} = Accounts.delete_or_anonymise_user(user)

    bijgewerkt = Repo.get!(Vps, vps.id)
    refute bijgewerkt.owner_email == user.email
    assert bijgewerkt.owner_email =~ "verwijderd"
  end

  test "bij een harde verwijdering blijft er geen adres achter op een losse VPS" do
    # Zonder geschiedenis wordt de rij écht verwijderd. De VPS'en houden dan een
    # genilificeerde `owner_id` -- en zonder deze stap een e-mailadres dat aan
    # niemand meer te koppelen is. Dat is slechter dan waar we begonnen.
    {:ok, user} =
      Accounts.register_user(%{
        email: "hard-#{System.unique_integer([:positive])}@bunk.test",
        password: "Str0ngPassphrase!42"
      })

    code = "r-#{System.unique_integer([:positive])}"
    region = %Region{} |> Region.changeset(%{code: code, name: "Regio"}) |> Repo.insert!()

    vps =
      %Vps{}
      |> Vps.changeset(%{
        name: "machine",
        region_id: region.id,
        vcpu: 1,
        ram_mb: 1024,
        disk_gb: 20,
        owner_email: user.email
      })
      |> Ecto.Changeset.change(%{owner_id: user.id, status: :deleted})
      |> Repo.insert!()

    {:ok, :deleted} = Accounts.delete_or_anonymise_user(user)

    assert is_nil(Repo.get!(Vps, vps.id).owner_email)
  end
end
