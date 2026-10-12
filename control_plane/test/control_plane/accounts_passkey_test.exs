defmodule ControlPlane.AccountsPasskeyTest do
  @moduledoc """
  De levenscyclus rond een passkey, met verzonnen sleutels.

  Wat hier bewezen wordt: dat de challenge eenmalig en tijdelijk is, dat rommel
  geweigerd wordt, dat sleutels bij hun eigenaar blijven en dat de
  challenge-structuren de vorm hebben die de browser verwacht. De ceremonie met
  een echte, tekenende sleutel staat in `passkey_ceremonie_test.exs`.
  """
  use ControlPlane.DataCase, async: false

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.Passkey
  alias ControlPlane.Accounts.PasskeyChallenges
  alias ControlPlane.Repo

  @password "test-only-password-4f2b9c1e"

  setup do
    PasskeyChallenges.reset()
    :ok
  end

  defp user(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: @password})
    u
  end

  # Een rij zoals wax hem zou opleveren, maar met een verzonnen sleutel: genoeg
  # om eigendom en lijsten te testen, niet om mee in te loggen.
  defp fake_passkey(u, label \\ "Telefoon") do
    Repo.insert!(%Passkey{
      user_id: u.id,
      credential_id: :crypto.strong_rand_bytes(32),
      public_key: Passkey.encode_cose_key(%{1 => 2, 3 => -7}),
      label: label
    })
  end

  describe "challenge-opslag" do
    test "een challenge is eenmalig" do
      id = PasskeyChallenges.put(:iets, %{user_id: "u", purpose: :register})
      assert {:ok, :iets, %{purpose: :register}} = PasskeyChallenges.take(id)
      # Een tweede antwoord op dezelfde challenge is een replay.
      assert :error = PasskeyChallenges.take(id)
    end

    test "een onbekend of verlopen id levert niets op" do
      assert :error = PasskeyChallenges.take("bestaat-niet")
      assert :error = PasskeyChallenges.take(nil)

      id = PasskeyChallenges.put(:oud, %{})
      # Terug in de tijd zetten: de vervaltijd is het vierde veld van de rij.
      :ets.update_element(:passkey_challenges, id, {4, 0})
      assert :error = PasskeyChallenges.take(id)
    end
  end

  describe "registreren" do
    test "de challenge heeft de vorm die navigator.credentials.create verwacht" do
      u = user("pk1@bunk.test")
      %{challenge_id: id, public_key: pk} = Accounts.start_passkey_registration(u)

      assert is_binary(id)
      assert {:ok, bytes} = Base.url_decode64(pk.challenge, padding: false)
      assert byte_size(bytes) >= 16
      assert pk.rp.name == "Bunk Hosting"
      assert pk.user.name == "pk1@bunk.test"
      assert pk.attestation == "none"
      assert pk.excludeCredentials == []
    end

    test "bestaande sleutels gaan mee als excludeCredentials" do
      u = user("pk2@bunk.test")
      pk = fake_passkey(u)
      %{public_key: opts} = Accounts.start_passkey_registration(u)

      assert [%{id: id}] = opts.excludeCredentials
      assert id == Base.url_encode64(pk.credential_id, padding: false)
    end

    test "rommel als antwoord wordt geweigerd en verbruikt de challenge" do
      u = user("pk3@bunk.test")
      %{challenge_id: id} = Accounts.start_passkey_registration(u)

      assert {:error, :invalid_passkey} =
               Accounts.finish_passkey_registration(u, id, %{
                 attestation_object: "geen cbor",
                 client_data_json: "{}",
                 label: "x"
               })

      # De challenge is nu weg: nog een poging met hetzelfde id kan niet.
      assert {:error, :challenge_expired} =
               Accounts.finish_passkey_registration(u, id, %{
                 attestation_object: "geen cbor",
                 client_data_json: "{}",
                 label: "x"
               })

      assert Accounts.list_passkeys(u) == []
    end

    test "andermans challenge is niet bruikbaar" do
      a = user("pk4a@bunk.test")
      b = user("pk4b@bunk.test")
      %{challenge_id: id} = Accounts.start_passkey_registration(a)

      assert {:error, :challenge_expired} =
               Accounts.finish_passkey_registration(b, id, %{
                 attestation_object: "x",
                 client_data_json: "{}",
                 label: "x"
               })
    end
  end

  describe "beheer" do
    test "passkeys_active? en de lijst volgen de rijen" do
      u = user("pk5@bunk.test")
      refute Accounts.passkeys_active?(u)

      fake_passkey(u, "Laptop")
      fake_passkey(u, "Telefoon")

      assert Accounts.passkeys_active?(u)
      assert ["Laptop", "Telefoon"] = u |> Accounts.list_passkeys() |> Enum.map(& &1.label)
    end

    test "verwijderen kan alleen je eigen sleutel" do
      a = user("pk6a@bunk.test")
      b = user("pk6b@bunk.test")
      pk = fake_passkey(a)

      # b met zijn eigen, juiste wachtwoord: de weigering gaat dan over eigendom.
      assert {:error, :not_found} = Accounts.delete_passkey(b, pk.id, @password)
      assert Accounts.passkeys_active?(a)

      assert {:ok, _} = Accounts.delete_passkey(a, pk.id, @password)
      refute Accounts.passkeys_active?(a)
    end

    test "verwijderen vraagt het huidige wachtwoord" do
      # Een passkey kan de tweede factor zijn; een sessie alleen mag hem niet
      # weghalen. Een fout wachtwoord laat hem staan, het goede niet.
      u = user("pk6c@bunk.test")
      pk = fake_passkey(u)

      assert {:error, :invalid_current_password} =
               Accounts.delete_passkey(u, pk.id, "niet-het-wachtwoord")

      assert {:error, :invalid_current_password} = Accounts.delete_passkey(u, pk.id, "")
      assert Accounts.passkeys_active?(u)

      assert {:ok, _} = Accounts.delete_passkey(u, pk.id, @password)
      refute Accounts.passkeys_active?(u)
    end

    test "een sleutel verdwijnt met het account" do
      u = user("pk7@bunk.test")
      fake_passkey(u)
      Repo.delete!(u)
      assert Repo.aggregate(Passkey, :count, :id) == 0
    end
  end

  describe "inloggen" do
    test "zonder passkeys is er geen challenge aan te bieden" do
      u = user("pk8@bunk.test")
      assert Accounts.start_passkey_login(u) == nil
    end

    test "met passkeys somt de challenge precies die sleutels op" do
      u = user("pk9@bunk.test")
      pk = fake_passkey(u)

      %{challenge_id: id, public_key: opts} = Accounts.start_passkey_login(u)
      assert is_binary(id)
      assert [%{id: cid}] = opts.allowCredentials
      assert cid == Base.url_encode64(pk.credential_id, padding: false)
    end

    test "een assertie van een onbekende sleutel wordt geweigerd" do
      u = user("pk10@bunk.test")
      fake_passkey(u)
      %{challenge_id: id} = Accounts.start_passkey_login(u)

      assert {:error, :invalid_passkey} =
               Accounts.finish_passkey_login(u, id, %{
                 credential_id: :crypto.strong_rand_bytes(32),
                 authenticator_data: "x",
                 signature: "x",
                 client_data_json: "{}"
               })
    end

    test "een verkeerde handtekening op een bekende sleutel wordt geweigerd" do
      u = user("pk11@bunk.test")
      pk = fake_passkey(u)
      %{challenge_id: id} = Accounts.start_passkey_login(u)

      assert {:error, :invalid_passkey} =
               Accounts.finish_passkey_login(u, id, %{
                 credential_id: pk.credential_id,
                 authenticator_data: <<0::size(37 * 8)>>,
                 signature: "nep",
                 client_data_json: ~s({"type":"webauthn.get","challenge":"x","origin":"x"})
               })

      # Niets bijgewerkt: last_used_at blijft leeg.
      assert Repo.get!(Passkey, pk.id).last_used_at == nil
    end
  end
end
