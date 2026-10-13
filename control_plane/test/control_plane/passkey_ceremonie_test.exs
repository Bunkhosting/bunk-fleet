defmodule ControlPlane.PasskeyCeremonieTest do
  @moduledoc """
  De passkey-ceremonie van begin tot eind, met een echte sleutel.

  `accounts_passkey_test.exs` bewijst de levenscyclus rond een passkey met
  verzonnen sleutels. Hier tekent `ControlPlane.SoftwareAuthenticator` met een
  echte P-256-sleutel, dus slaagt een geldige ceremonie echt en faalt elke
  manipulatie op de controle die ervoor bedoeld is.

  Elke negatieve test heeft een tegenproef: dezelfde opbouw zonder die ene
  manipulatie slaagt wél. Zonder die tegenproef zou een kapotte testopzet --
  een verkeerde CBOR-byte, een handtekening over de verkeerde bytes -- elke
  weigering hier groen maken. Het eerste blok praat daarom rechtstreeks met wax,
  zodat ook zichtbaar is OP WELKE controle een manipulatie strandt; `Passkeys`
  maakt van elke wax-weigering één `:invalid_passkey` en verbergt dat.
  """
  use ControlPlane.DataCase, async: false

  import ControlPlane.Fixtures

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.Passkey
  alias ControlPlane.Accounts.PasskeyChallenges
  alias ControlPlane.Accounts.Passkeys
  alias ControlPlane.Repo
  alias ControlPlane.SoftwareAuthenticator, as: Authenticator

  setup do
    PasskeyChallenges.reset()
    :ok
  end

  # {naam, opties voor de authenticator, verwachte wax-fout}. De verwachte fout
  # is de `reason` van een Wax.InvalidClientDataError, of de module van een
  # andere wax-fout. Dezelfde lijst draait twee keer: tegen wax (op welke
  # controle strandt het) en tegen Passkeys (wat de klant ervan merkt, en dat er
  # niets is opgeslagen).
  @registratie_manipulaties [
    {"een andere challenge", [challenge: <<1::256>>], :challenge_mismatch},
    {"een andere origin", [origin: "https://bunkhosting.nl.evil.example"], :origin_mismatch},
    {"het type van een inlogpoging", [type: "webauthn.get"], :create_type_expected},
    {"een sleutel voor een ander domein", [rp_id: "evil.example"], :rp_id_mismatch},
    {"geen aanwezige gebruiker", [flags: 0x44], :flag_user_present_not_set},
    {"een onbekend attestatieformaat", [fmt: "x"], Wax.UnsupportedAttestationFormatError}
  ]

  @assertie_manipulaties [
    {"een andere challenge", [challenge: <<1::256>>], :challenge_mismatch},
    {"een andere origin", [origin: "https://bunkhosting.nl.evil.example"], :origin_mismatch},
    {"het type van een registratie", [type: "webauthn.create"], :get_type_expected},
    {"een sleutel voor een ander domein", [rp_id: "evil.example"], :rp_id_mismatch},
    {"geen aanwezige gebruiker", [flags: 0x04], :flag_user_present_not_set},
    {"getekend met een andere sleutel", [signer: :ander], Wax.InvalidSignatureError}
  ]

  defp registreer(user, auth, opts \\ []) do
    %{challenge_id: id, public_key: pk} = Passkeys.start_passkey_registration(user)
    antwoord = Authenticator.registratie(auth, pk, opts)
    Passkeys.finish_passkey_registration(user, id, Map.put(antwoord, :label, "Testsleutel"))
  end

  defp inloggen(user, auth, opts \\ []) do
    %{challenge_id: id, public_key: pk} = Passkeys.start_passkey_login(user)
    Passkeys.finish_passkey_login(user, id, Authenticator.assertie(auth, pk, ondertekenaar(opts)))
  end

  # `signer: :ander` in de tabellen staat voor "een willekeurige andere
  # authenticator"; een sleutel kan niet in een moduleattribuut.
  defp ondertekenaar(opts) do
    case Keyword.fetch(opts, :signer) do
      {:ok, :ander} -> Keyword.put(opts, :signer, Authenticator.new())
      _ -> opts
    end
  end

  # Een gebruiker met één geregistreerde passkey, via de echte ceremonie.
  defp met_passkey(opts \\ []) do
    user = confirmed_user_fixture()
    auth = Authenticator.new()
    assert {:ok, %Passkey{}} = registreer(user, auth, opts)
    {user, auth}
  end

  defp opgeslagen(auth), do: Repo.get_by!(Passkey, credential_id: auth.credential_id)

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  defp wax_register(ctx, opts) do
    a = Authenticator.registratie(ctx.auth, ctx.reg_pk, opts)
    Wax.register(a.attestation_object, a.client_data_json, ctx.registratie)
  end

  defp wax_authenticate(ctx, a) do
    Wax.authenticate(
      a.credential_id,
      a.authenticator_data,
      a.signature,
      a.client_data_json,
      ctx.inlog,
      [{ctx.auth.credential_id, Authenticator.cose_key(ctx.auth)}]
    )
  end

  defp assert_wax_fout({:error, %Wax.InvalidClientDataError{reason: reden}}, verwacht),
    do: assert(reden == verwacht)

  defp assert_wax_fout({:error, %module{}}, verwacht), do: assert(module == verwacht)

  defp assert_wax_fout(anders, verwacht),
    do: flunk("verwacht een weigering (#{inspect(verwacht)}), kreeg #{inspect(anders)}")

  describe "de software-authenticator tegen wax" do
    # Eerst bewijzen dat de opbouw klopt. Slaagt dit niet, dan zegt geen enkele
    # weigering verderop iets.
    setup do
      auth = Authenticator.new()

      registratie =
        Wax.new_registration_challenge(
          origin: Authenticator.origin(),
          rp_id: :auto,
          attestation: "none"
        )

      inlog = Wax.new_authentication_challenge(origin: Authenticator.origin(), rp_id: :auto)

      %{
        auth: auth,
        registratie: registratie,
        reg_pk: %{challenge: b64(registratie.bytes), rp: %{id: registratie.rp_id}},
        inlog: inlog,
        inlog_pk: %{challenge: b64(inlog.bytes), rpId: inlog.rp_id}
      }
    end

    test "een geldige registratie levert precies de sleutel van de authenticator op", ctx do
      assert {:ok, {auth_data, {:none, nil, nil}}} = wax_register(ctx, [])

      cred = auth_data.attested_credential_data
      assert cred.credential_id == ctx.auth.credential_id
      assert cred.credential_public_key == Authenticator.cose_key(ctx.auth)
      assert auth_data.flag_user_present
      assert auth_data.flag_user_verified
    end

    test "een geldige assertie komt door de handtekeningcontrole", ctx do
      a = Authenticator.assertie(ctx.auth, ctx.inlog_pk, sign_count: 9)
      assert {:ok, auth_data} = wax_authenticate(ctx, a)
      assert auth_data.sign_count == 9
    end

    for {naam, opts, verwacht} <- @registratie_manipulaties do
      test "registratie strandt op de bedoelde controle: #{naam}", ctx do
        assert_wax_fout(wax_register(ctx, unquote(opts)), unquote(verwacht))
      end
    end

    for {naam, opts, verwacht} <- @assertie_manipulaties do
      test "assertie strandt op de bedoelde controle: #{naam}", ctx do
        a = Authenticator.assertie(ctx.auth, ctx.inlog_pk, ondertekenaar(unquote(opts)))
        assert_wax_fout(wax_authenticate(ctx, a), unquote(verwacht))
      end
    end

    test "authenticatorData achteraf wijzigen breekt de handtekening", ctx do
      a = Authenticator.assertie(ctx.auth, ctx.inlog_pk, sign_count: 1)
      # De teller na het tekenen ophogen: precies wat een kloon zou willen om
      # langs de tellercontrole te komen.
      <<begin::binary-size(33), _teller::32>> = a.authenticator_data
      vervalst = %{a | authenticator_data: begin <> <<1000::32>>}

      assert_wax_fout(wax_authenticate(ctx, vervalst), Wax.InvalidSignatureError)
    end

    test "clientDataJSON achteraf wijzigen breekt de handtekening", ctx do
      a = Authenticator.assertie(ctx.auth, ctx.inlog_pk)
      # Zelfde challenge, origin en type -- alleen een extra veld. Wax leest de
      # JSON nog steeds goed; alleen de hash klopt niet meer met wat getekend is.
      json = String.replace_suffix(a.client_data_json, "}", ~s(,"x":1}))
      vervalst = %{a | client_data_json: json}

      assert_wax_fout(wax_authenticate(ctx, vervalst), Wax.InvalidSignatureError)
    end
  end

  describe "registreren" do
    test "een geldige ceremonie bewaart de sleutel van de authenticator" do
      user = confirmed_user_fixture()
      auth = Authenticator.new()
      refute Accounts.has_second_factor?(user)

      assert {:ok, %Passkey{} = pk} = registreer(user, auth, sign_count: 3)

      assert pk.credential_id == auth.credential_id
      assert Passkey.cose_key(pk) == Authenticator.cose_key(auth)
      assert pk.sign_count == 3
      assert pk.label == "Testsleutel"
      assert Accounts.has_second_factor?(user)
    end

    for {naam, opts, _verwacht} <- @registratie_manipulaties do
      test "geweigerd: #{naam}" do
        user = confirmed_user_fixture()
        auth = Authenticator.new()

        assert {:error, :invalid_passkey} = registreer(user, auth, unquote(opts))
        assert Passkeys.list_passkeys(user) == []

        # Tegenproef: dezelfde gebruiker, dezelfde authenticator, zonder de
        # manipulatie.
        assert {:ok, _} = registreer(user, auth)
      end
    end

    test "hetzelfde antwoord twee keer insturen is een replay" do
      user = confirmed_user_fixture()
      %{challenge_id: id, public_key: pk} = Passkeys.start_passkey_registration(user)
      antwoord = Authenticator.new() |> Authenticator.registratie(pk) |> Map.put(:label, "x")

      assert {:ok, _} = Passkeys.finish_passkey_registration(user, id, antwoord)

      assert {:error, :challenge_expired} =
               Passkeys.finish_passkey_registration(user, id, antwoord)

      assert [_] = Passkeys.list_passkeys(user)
    end

    test "een antwoord op challenge A is niet bruikbaar onder challenge B" do
      user = confirmed_user_fixture()
      auth = Authenticator.new()
      %{challenge_id: _a, public_key: pk_a} = Passkeys.start_passkey_registration(user)
      %{challenge_id: b, public_key: pk_b} = Passkeys.start_passkey_registration(user)
      refute pk_a.challenge == pk_b.challenge

      voor_a = auth |> Authenticator.registratie(pk_a) |> Map.put(:label, "x")
      assert {:error, :invalid_passkey} = Passkeys.finish_passkey_registration(user, b, voor_a)
      assert Passkeys.list_passkeys(user) == []

      # Tegenproef met een verse challenge: het antwoord op B, onder B.
      %{challenge_id: c, public_key: pk_c} = Passkeys.start_passkey_registration(user)
      voor_c = auth |> Authenticator.registratie(pk_c) |> Map.put(:label, "x")
      assert {:ok, _} = Passkeys.finish_passkey_registration(user, c, voor_c)
    end

    test "een inlog-challenge kan geen passkey registreren" do
      # Wax zelf zou dit doorlaten: de challenge-bytes kloppen, de browser zet
      # zelf "webauthn.create" in clientDataJSON, en attestatie "none" is ook de
      # standaard van een inlog-challenge. Alleen het doel dat de opslag bij de
      # challenge bewaart houdt het tegen. Eerst crashte dit met een
      # WithClauseError: een 500.
      {user, _} = met_passkey()
      nieuw = Authenticator.new()
      %{challenge_id: id, public_key: inlog_pk} = Passkeys.start_passkey_login(user)

      antwoord =
        nieuw
        |> Authenticator.registratie(%{challenge: inlog_pk.challenge, rp: %{id: inlog_pk.rpId}})
        |> Map.put(:label, "x")

      assert {:error, :challenge_expired} =
               Passkeys.finish_passkey_registration(user, id, antwoord)

      assert [_] = Passkeys.list_passkeys(user)

      # Tegenproef: dezelfde nieuwe authenticator via een registratie-challenge.
      assert {:ok, _} = registreer(user, nieuw)
    end

    test "een verlopen challenge weigert ook een verder geldig antwoord" do
      user = confirmed_user_fixture()
      auth = Authenticator.new()
      %{challenge_id: id, public_key: pk} = Passkeys.start_passkey_registration(user)
      antwoord = auth |> Authenticator.registratie(pk) |> Map.put(:label, "x")

      # De vervaltijd is het vierde veld van de rij; zet hem in het verleden.
      :ets.update_element(:passkey_challenges, id, {4, 0})

      assert {:error, :challenge_expired} =
               Passkeys.finish_passkey_registration(user, id, antwoord)

      assert {:ok, _} = registreer(user, auth)
    end

    test "wax bewaakt de timeout ook als de opslag de challenge nog heeft" do
      # Twee sloten op dezelfde deur: de opslag vergeet na vijf minuten, en wax
      # weigert een challenge die ouder is dan zijn eigen timeout. Hier staat de
      # rij er nog, maar is de challenge erin te oud.
      user = confirmed_user_fixture()
      auth = Authenticator.new()
      %{challenge_id: id, public_key: pk} = Passkeys.start_passkey_registration(user)
      antwoord = auth |> Authenticator.registratie(pk) |> Map.put(:label, "x")

      [{^id, challenge, meta, verloopt}] = :ets.lookup(:passkey_challenges, id)
      oud = %{challenge | issued_at: challenge.issued_at - challenge.timeout - 1}
      :ets.insert(:passkey_challenges, {id, oud, meta, verloopt})

      assert {:error, :invalid_passkey} =
               Passkeys.finish_passkey_registration(user, id, antwoord)

      assert {:ok, _} = registreer(user, auth)
    end

    test "dezelfde authenticator twee keer registreren levert geen tweede rij op" do
      {user, auth} = met_passkey()

      assert {:error, %Ecto.Changeset{} = cs} = registreer(user, auth)
      assert %{credential_id: [_]} = errors_on(cs)
      assert [_] = Passkeys.list_passkeys(user)
    end

    test "andermans credential-id is niet over te nemen" do
      # Bij attestatie "none" ondertekent niemand de registratie: wie een
      # credential-id kent, kan het met zijn eigen sleutel aanbieden. De unieke
      # index houdt dat tegen, en de sleutel van de eigenaar blijft staan.
      {eigenaar, auth} = met_passkey()
      indringer = confirmed_user_fixture()
      kaper = %{Authenticator.new() | credential_id: auth.credential_id}

      assert {:error, %Ecto.Changeset{}} = registreer(indringer, kaper)
      assert Passkeys.list_passkeys(indringer) == []
      assert Passkey.cose_key(opgeslagen(auth)) == Authenticator.cose_key(auth)

      # De eigenaar logt nog gewoon in met zijn eigen sleutel.
      assert {:ok, _} = inloggen(eigenaar, auth)
    end
  end

  describe "inloggen" do
    test "een geldige assertie slaagt en werkt teller en gebruiksmoment bij" do
      {user, auth} = met_passkey(sign_count: 1)
      assert opgeslagen(auth).last_used_at == nil

      assert {:ok, %Passkey{} = pk} = inloggen(user, auth, sign_count: 2)
      assert pk.sign_count == 2
      assert %DateTime{} = pk.last_used_at
      assert opgeslagen(auth).sign_count == 2
    end

    for {naam, opts, _verwacht} <- @assertie_manipulaties do
      test "geweigerd: #{naam}" do
        {user, auth} = met_passkey()

        assert {:error, :invalid_passkey} = inloggen(user, auth, unquote(opts))
        assert opgeslagen(auth).last_used_at == nil

        # Tegenproef: dezelfde gebruiker en sleutel, zonder de manipulatie.
        assert {:ok, _} = inloggen(user, auth)
      end
    end

    test "hetzelfde antwoord twee keer insturen is een replay" do
      {user, auth} = met_passkey()
      %{challenge_id: id, public_key: pk} = Passkeys.start_passkey_login(user)
      assertie = Authenticator.assertie(auth, pk)

      assert {:ok, _} = Passkeys.finish_passkey_login(user, id, assertie)
      assert {:error, :challenge_expired} = Passkeys.finish_passkey_login(user, id, assertie)

      # Ook onder een verse challenge doet het oude antwoord niets: het is over
      # andere bytes getekend.
      %{challenge_id: nieuw} = Passkeys.start_passkey_login(user)
      assert {:error, :invalid_passkey} = Passkeys.finish_passkey_login(user, nieuw, assertie)
    end

    test "een sleutel die niet bij dit account hoort wordt geweigerd" do
      {user, auth} = met_passkey()
      onbekend = Authenticator.new()

      # Correct getekend over de juiste challenge -- alleen nooit geregistreerd.
      assert {:error, :invalid_passkey} = inloggen(user, onbekend)
      assert {:ok, _} = inloggen(user, auth)
    end

    test "andermans passkey opent jouw account niet" do
      # Wie het wachtwoord van B heeft en een eigen passkey op account A, mag met
      # die passkey niet bij B binnen: de opzoeking is per account.
      {a, auth_a} = met_passkey()
      {b, auth_b} = met_passkey()

      assert {:error, :invalid_passkey} = inloggen(b, auth_a)
      assert opgeslagen(auth_a).last_used_at == nil

      assert {:ok, _} = inloggen(b, auth_b)
      assert {:ok, _} = inloggen(a, auth_a)
    end

    test "andermans inlog-challenge is niet bruikbaar" do
      {a, _} = met_passkey()
      {b, auth_b} = met_passkey()
      %{challenge_id: id, public_key: pk} = Passkeys.start_passkey_login(a)

      assert {:error, :challenge_expired} =
               Passkeys.finish_passkey_login(b, id, Authenticator.assertie(auth_b, pk))

      assert {:ok, _} = inloggen(b, auth_b)
    end

    test "een registratie-challenge kan niet inloggen" do
      # Eerst crashte dit met een WithClauseError: een 500 op het inlogpad.
      {user, auth} = met_passkey()
      %{challenge_id: id, public_key: reg_pk} = Passkeys.start_passkey_registration(user)
      assertie = Authenticator.assertie(auth, %{challenge: reg_pk.challenge, rpId: reg_pk.rp.id})

      assert {:error, :challenge_expired} = Passkeys.finish_passkey_login(user, id, assertie)
      assert {:ok, _} = inloggen(user, auth)
    end

    test "na verwijderen opent de sleutel niets meer" do
      {user, auth} = met_passkey()
      # Een tweede sleutel, anders is er na het verwijderen geen inlog-challenge
      # meer uit te geven en zegt deze test niets over de verwijderde.
      assert {:ok, _} = registreer(user, Authenticator.new())
      assert {:ok, _} = inloggen(user, auth)

      assert {:ok, _} =
               Passkeys.delete_passkey(user, opgeslagen(auth).id, valid_user_password())

      assert {:error, :invalid_passkey} = inloggen(user, auth)
    end
  end

  describe "de tekenteller" do
    test "een teller die oploopt is gewoon" do
      {user, auth} = met_passkey(sign_count: 1)

      assert {:ok, _} = inloggen(user, auth, sign_count: 2)
      assert {:ok, _} = inloggen(user, auth, sign_count: 5)
      assert opgeslagen(auth).sign_count == 5
    end

    test "een teller die stilstaat of terugloopt wijst op een kloon" do
      {user, auth} = met_passkey(sign_count: 1)
      assert {:ok, _} = inloggen(user, auth, sign_count: 5)

      assert {:error, :invalid_passkey} = inloggen(user, auth, sign_count: 5)
      assert {:error, :invalid_passkey} = inloggen(user, auth, sign_count: 4)
      assert opgeslagen(auth).sign_count == 5

      # Tegenproef: hoger dan de laatste mag wel.
      assert {:ok, _} = inloggen(user, auth, sign_count: 6)
    end

    test "een teller die naar nul springt wijst ook op een kloon" do
      # Dit ging eerst door, en de 0 werd opgeslagen: daarna stond de
      # kloondetectie voor deze sleutel voorgoed uit, want 0 telde als "geen
      # teller". Een kloon hoefde dus maar één keer 0 te sturen.
      {user, auth} = met_passkey(sign_count: 1)
      assert {:ok, _} = inloggen(user, auth, sign_count: 5)

      assert {:error, :invalid_passkey} = inloggen(user, auth, sign_count: 0)
      assert opgeslagen(auth).sign_count == 5

      assert {:ok, _} = inloggen(user, auth, sign_count: 6)
    end

    test "een authenticator zonder teller stuurt altijd nul, en dat mag" do
      # Synchroniserende passkeys (iCloud, Google) tellen niet. Zolang beide
      # kanten nul zijn valt er niets te vergelijken.
      {user, auth} = met_passkey(sign_count: 0)

      assert {:ok, _} = inloggen(user, auth, sign_count: 0)
      assert {:ok, _} = inloggen(user, auth, sign_count: 0)
      assert opgeslagen(auth).sign_count == 0
    end
  end
end
