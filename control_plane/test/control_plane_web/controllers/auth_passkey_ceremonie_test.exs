defmodule ControlPlaneWeb.AuthPasskeyCeremonieTest do
  @moduledoc """
  De passkey-ceremonie via de API, precies zoals het dashboard hem doorloopt.

  De browserkant is nooit end-to-end getest. Wat hier wel kan: de bytes maken
  die een browser zou sturen (`ControlPlane.SoftwareAuthenticator`, met een
  echte P-256-sleutel), ze base64url-coderen zoals `lib/api.ts` doet, en kijken
  of de API er een sessie voor geeft -- en niets voor een replay, een kloon of
  een verzoek dat het verkeerde soort challenge gebruikt.

  Wat ook hier niet bewezen wordt: dat een echte browser dezelfde bytes maakt.
  Dat hangt aan de WebAuthn-specificatie, niet aan onze code.
  """
  use ControlPlaneWeb.ConnCase, async: false

  import ControlPlane.Fixtures

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.PasskeyChallenges
  alias ControlPlane.Accounts.Passkeys
  alias ControlPlane.SoftwareAuthenticator, as: Authenticator

  setup do
    PasskeyChallenges.reset()
    :ok
  end

  defp ingelogd(user) do
    token = user |> Accounts.generate_user_session_token() |> Base.url_encode64(padding: false)
    put_req_header(build_conn(), "authorization", "Bearer " <> token)
  end

  # De sessie komt sinds het token uit de body is gehaald alleen nog als
  # HttpOnly-cookie terug. Zonder die cookie is er niet ingelogd, wat de body
  # ook zegt.
  defp sessie(conn) do
    case conn.resp_cookies["bunk_session"] do
      %{value: waarde} when is_binary(waarde) and waarde != "" -> waarde
      _ -> nil
    end
  end

  defp ingelogd!(conn) do
    assert %{"user" => _} = json_response(conn, 200)
    assert is_binary(sessie(conn))
    conn
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  # Een factor toevoegen aan een account dat er al een heeft, vraagt een sessie
  # die met een tweede factor begon; zo komt wie al een passkey heeft ook binnen.
  # Dat een sessie zonder factor hier geweigerd wordt, staat in AuthTotpTest.
  defp ingelogd_met_factor(user) do
    token =
      user |> Accounts.generate_user_session_token(mfa: true) |> Base.url_encode64(padding: false)

    put_req_header(build_conn(), "authorization", "Bearer " <> token)
  end

  # Stap één van het beveiligingsscherm: een registratie-challenge halen.
  defp registratie_challenge(user) do
    user
    |> ingelogd_met_factor()
    |> post(~p"/api/v1/auth/passkeys/challenge")
    |> json_response(200)
  end

  # Stap twee: het antwoord van de authenticator terugsturen.
  defp registratie_insturen(user, challenge_id, antwoord, label \\ "Telefoon") do
    user
    |> ingelogd_met_factor()
    |> post(~p"/api/v1/auth/passkeys", %{
      "challenge_id" => challenge_id,
      "label" => label,
      "credential" => Authenticator.registratie_json(antwoord)
    })
  end

  defp registreer(user, auth, label \\ "Telefoon") do
    %{"challenge_id" => cid, "public_key" => pk} = registratie_challenge(user)
    registratie_insturen(user, cid, Authenticator.registratie(auth, pk), label)
  end

  # Elke poging vanaf een ander adres, zoals bij een botnet: de limiet per IP
  # mag hier niet degene zijn die grijpt.
  defp login(user, extra \\ %{}, n \\ 1) do
    build_conn()
    |> put_req_header("cf-connecting-ip", "198.51.100.#{rem(n, 250) + 1}")
    |> vanaf_dashboard()
    |> post(
      ~p"/api/v1/auth/login",
      Map.merge(%{"email" => user.email, "password" => valid_user_password()}, extra)
    )
  end

  # Een gebruiker met een passkey die via de API is geregistreerd.
  defp met_passkey do
    user = confirmed_user_fixture()
    auth = Authenticator.new()
    assert %{"passkey" => _} = user |> registreer(auth) |> json_response(201)
    {user, auth}
  end

  # Het wachtwoord, en dan de challenge die het antwoord meegeeft.
  defp inlog_challenge(user) do
    assert %{"mfa_required" => true, "passkey_challenge" => %{} = challenge} =
             user |> login() |> json_response(200)

    challenge
  end

  defp met_assertie(user, auth, challenge, opts \\ [], n \\ 1) do
    assertie = Authenticator.assertie(auth, challenge["public_key"], opts)
    passkey = Authenticator.assertie_json(assertie, challenge["challenge_id"])
    login(user, %{"passkey" => passkey}, n)
  end

  # Een assertie met de juiste vorm en het juiste credential-id, maar getekend
  # met een andere sleutel: een echte mislukte poging, die de challenge
  # verbruikt. Geeft de nieuwe challenge terug die bij de weigering hoort.
  defp foute_poging(user, auth, challenge, n) do
    body =
      user
      |> met_assertie(auth, challenge, [signer: Authenticator.new()], n)
      |> json_response(401)

    assert body["error"] == "invalid_passkey"
    body["passkey_challenge"]
  end

  describe "de hele ceremonie" do
    test "registreren en daarna inloggen met de passkey geeft een sessie met tweede factor" do
      user = confirmed_user_fixture()
      auth = Authenticator.new()

      %{"challenge_id" => cid, "public_key" => pk} = registratie_challenge(user)
      # De rp-id die de browser krijgt moet de host van de origin zijn, anders
      # weigert een echte browser de ceremonie al voordat wij iets zien.
      assert pk["rp"]["id"] == URI.parse(Authenticator.origin()).host

      assert %{"passkey" => passkey} =
               user
               |> registratie_insturen(cid, Authenticator.registratie(auth, pk))
               |> json_response(201)

      # Wat naar buiten gaat is een label en wat tijden, nooit de sleutel.
      assert passkey |> Map.keys() |> Enum.sort() == ~w(created_at id label last_used_at)
      assert passkey["label"] == "Telefoon"

      challenge = inlog_challenge(user)

      assert challenge["public_key"]["allowCredentials"] == [
               %{"type" => "public-key", "id" => b64(auth.credential_id)}
             ]

      antwoord = user |> met_assertie(auth, challenge) |> ingelogd!()
      assert json_response(antwoord, 200)["user"]["passkeys_enabled"] == true

      me =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> sessie(antwoord))
        |> get(~p"/api/v1/auth/me")
        |> json_response(200)

      # Het beheerpaneel vraagt hierom; een passkey telt als tweede factor.
      assert me["user"]["session_mfa"] == true

      assert %{"passkeys" => [%{"id" => id, "last_used_at" => gebruikt}]} =
               user |> ingelogd() |> get(~p"/api/v1/auth/passkeys") |> json_response(200)

      assert id == passkey["id"]
      assert is_binary(gebruikt)
    end

    test "hetzelfde inlogantwoord twee keer geeft geen tweede sessie" do
      {user, auth} = met_passkey()
      challenge = inlog_challenge(user)
      assertie = Authenticator.assertie(auth, challenge["public_key"])
      passkey = Authenticator.assertie_json(assertie, challenge["challenge_id"])

      user |> login(%{"passkey" => passkey}) |> ingelogd!()

      tweede = user |> login(%{"passkey" => passkey})
      assert json_response(tweede, 401)["error"] == "invalid_passkey"
      refute sessie(tweede)
    end

    test "een gekloonde sleutel met een teruggelopen teller komt er niet in" do
      {user, auth} = met_passkey()
      eerste = met_assertie(user, auth, inlog_challenge(user), sign_count: 7)
      ingelogd!(eerste)

      tweede = met_assertie(user, auth, inlog_challenge(user), sign_count: 3)
      assert json_response(tweede, 401)["error"] == "invalid_passkey"
      refute sessie(tweede)
    end
  end

  describe "foute passkeys tellen mee in de 2FA-limiet" do
    test "na vijf mislukte pogingen helpt ook de goede passkey even niet" do
      {user, auth} = met_passkey()

      challenge = Enum.reduce(1..5, inlog_challenge(user), &foute_poging(user, auth, &2, &1))

      geweigerd = user |> met_assertie(auth, challenge, [], 99)
      assert json_response(geweigerd, 401)["error"] == "invalid_passkey"
      refute sessie(geweigerd)
    end

    test "onder de grens werkt de goede passkey gewoon" do
      # De tegenproef: zonder deze slaagde de test hierboven ook als inloggen
      # met een passkey in deze opzet altijd mislukte.
      {user, auth} = met_passkey()

      challenge = Enum.reduce(1..4, inlog_challenge(user), &foute_poging(user, auth, &2, &1))

      user |> met_assertie(auth, challenge, [], 99) |> ingelogd!()
    end
  end

  describe "registreren: foutpaden" do
    test "een inlog-challenge registreert geen passkey" do
      # Dit was een 500: de challenge kwam terug met het verkeerde doel en viel
      # door elke tak van de foutafhandeling heen.
      {user, _auth} = met_passkey()
      nieuw = Authenticator.new()
      %{"challenge_id" => cid, "public_key" => pk} = inlog_challenge(user)
      als_registratie = %{"challenge" => pk["challenge"], "rp" => %{"id" => pk["rpId"]}}

      assert %{"error" => "challenge_expired"} =
               user
               |> registratie_insturen(cid, Authenticator.registratie(nieuw, als_registratie))
               |> json_response(422)

      # Tegenproef: dezelfde nieuwe sleutel via een registratie-challenge.
      assert %{"passkey" => _} = user |> registreer(nieuw) |> json_response(201)
    end

    test "hetzelfde registratieantwoord twee keer is een replay" do
      user = confirmed_user_fixture()
      %{"challenge_id" => cid, "public_key" => pk} = registratie_challenge(user)
      antwoord = Authenticator.registratie(Authenticator.new(), pk)

      assert %{"passkey" => _} = user |> registratie_insturen(cid, antwoord) |> json_response(201)

      assert %{"error" => "challenge_expired"} =
               user |> registratie_insturen(cid, antwoord) |> json_response(422)
    end

    test "dezelfde sleutel twee keer registreren is een nette weigering" do
      {user, auth} = met_passkey()

      assert %{"error" => "invalid_passkey"} = user |> registreer(auth) |> json_response(422)
      assert [_] = Passkeys.list_passkeys(user)
    end

    test "een label dat geen tekst is valt terug op de standaardnaam" do
      # Dit was een 500: to_string/1 op een JSON-object raist.
      user = confirmed_user_fixture()

      assert %{"passkey" => %{"label" => "Passkey"}} =
               user |> registreer(Authenticator.new(), %{"x" => 1}) |> json_response(201)
    end

    test "een te lang label wordt geweigerd en slaat niets op" do
      user = confirmed_user_fixture()
      auth = Authenticator.new()

      assert %{"error" => "invalid_passkey"} =
               user |> registreer(auth, String.duplicate("a", 61)) |> json_response(422)

      assert Passkeys.list_passkeys(user) == []

      # Tegenproef: zestig tekens mag.
      assert %{"passkey" => _} =
               user |> registreer(auth, String.duplicate("a", 60)) |> json_response(201)
    end
  end

  describe "verwijderen" do
    # Zoals het dashboard het doet: het huidige wachtwoord in de body van de
    # DELETE. `nil` laat het veld weg.
    defp verwijder(user, id, wachtwoord) do
      body = if wachtwoord, do: %{"current_password" => wachtwoord}, else: %{}
      user |> ingelogd() |> delete(~p"/api/v1/auth/passkeys/#{id}", body)
    end

    test "je eigen passkey verwijderen haalt de tweede factor weg" do
      {user, _auth} = met_passkey()
      [pk] = Passkeys.list_passkeys(user)

      assert user |> verwijder(pk.id, valid_user_password()) |> response(204)
      assert Passkeys.list_passkeys(user) == []

      # Zonder tweede factor is het wachtwoord weer genoeg.
      user |> login() |> ingelogd!()
    end

    test "zonder of met een fout wachtwoord blijft de passkey staan" do
      # Het gat: met alleen een gekaapte sessie de passkey weghalen, en daarmee
      # de tweede factor. De sessie hier is geldig; alleen het wachtwoord mist.
      {user, auth} = met_passkey()
      [pk] = Passkeys.list_passkeys(user)

      assert %{"error" => "missing_password"} =
               user |> verwijder(pk.id, nil) |> json_response(422)

      assert %{"error" => "wrong_current_password"} =
               user |> verwijder(pk.id, "niet-het-wachtwoord") |> json_response(422)

      assert [_] = Passkeys.list_passkeys(user)

      # En de passkey werkt nog: wachtwoord alleen geeft geen sessie, de
      # passkey erbij wel.
      challenge = inlog_challenge(user)
      user |> met_assertie(auth, challenge) |> ingelogd!()

      # De tegenproef op dezelfde sessie en hetzelfde id: met het juiste
      # wachtwoord gaat hij wel weg. Zonder deze stap slaagden de weigeringen
      # hierboven ook als de route om een andere reden kapot was.
      assert user |> verwijder(pk.id, valid_user_password()) |> response(204)
      assert Passkeys.list_passkeys(user) == []
    end

    test "een fout wachtwoord telt mee voor het inlogslot" do
      # Anders is dit de plek om met een gekaapte sessie ongelimiteerd naar het
      # wachtwoord te raden. Na genoeg fouten helpt ook het goede even niet.
      {user, _} = met_passkey()
      [pk] = Passkeys.list_passkeys(user)

      for _ <- 1..10, do: verwijder(user, pk.id, "niet-het-wachtwoord")

      assert %{"error" => "wrong_current_password"} =
               user |> verwijder(pk.id, valid_user_password()) |> json_response(422)

      assert [_] = Passkeys.list_passkeys(user)
    end

    test "andermans passkey verwijderen kan niet, en verraadt niet dat hij bestaat" do
      {eigenaar, _} = met_passkey()
      [pk] = Passkeys.list_passkeys(eigenaar)
      vreemde = confirmed_user_fixture()

      # Met het eigen, juiste wachtwoord van de vreemde: anders strandt het al
      # op het wachtwoord en zegt deze test niets over eigendom.
      bestaand = verwijder(vreemde, pk.id, valid_user_password())
      onbekend = verwijder(vreemde, Ecto.UUID.generate(), valid_user_password())

      # Hetzelfde antwoord voor "bestaat niet" en "niet van jou".
      assert json_response(bestaand, 404) == json_response(onbekend, 404)
      assert [_] = Passkeys.list_passkeys(eigenaar)
    end

    test "een id dat geen uuid is, of geen sessie, levert niets op" do
      {user, _} = met_passkey()

      geen_uuid = verwijder(user, "geen-uuid", valid_user_password())
      assert %{"error" => "not_found"} = json_response(geen_uuid, 404)

      [pk] = Passkeys.list_passkeys(user)

      assert %{"error" => "unauthorized"} =
               build_conn()
               |> delete(~p"/api/v1/auth/passkeys/#{pk.id}", %{
                 "current_password" => valid_user_password()
               })
               |> json_response(401)

      assert [_] = Passkeys.list_passkeys(user)
    end
  end
end
