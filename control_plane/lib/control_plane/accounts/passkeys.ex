defmodule ControlPlane.Accounts.Passkeys do
  @moduledoc """
  Passkeys (WebAuthn) als tweede factor naast, of in plaats van, TOTP.

  De cryptografie zit in wax; wat hier staat is de levenscyclus: challenge
  uitgeven, antwoord controleren, sleutel bewaren, en bij het inloggen de
  handtekening natrekken tegen de sleutels van precies dit account.

  Registreren gaat via `start_passkey_registration/1` en
  `finish_passkey_registration/3`, inloggen via `start_passkey_login/1` en
  `finish_passkey_login/3`. De uitgegeven challenges bewaart
  `ControlPlane.Accounts.PasskeyChallenges`, eenmalig en met een termijn.
  Een passkey verwijderen vraagt het huidige wachtwoord, met dezelfde
  herbevestiging als wachtwoord wijzigen in `ControlPlane.Accounts`.
  """
  import Ecto.Query, warn: false

  alias ControlPlane.Accounts
  alias ControlPlane.Accounts.Passkey
  alias ControlPlane.Accounts.PasskeyChallenges
  alias ControlPlane.Accounts.User
  alias ControlPlane.Clock
  alias ControlPlane.Repo

  @passkey_timeout_seconds 300

  @doc "True zodra de gebruiker minstens één passkey heeft geregistreerd."
  def passkeys_active?(%User{id: user_id}) do
    Repo.exists?(from p in Passkey, where: p.user_id == ^user_id)
  end

  @doc "De passkeys van een gebruiker, oudste eerst. Zonder de sleutel zelf."
  def list_passkeys(%User{id: user_id}) do
    Repo.all(from p in Passkey, where: p.user_id == ^user_id, order_by: [asc: p.inserted_at])
  end

  @doc """
  Geeft een registratie-challenge uit.

  Het antwoord is wat `navigator.credentials.create()` als `publicKey` verwacht,
  plus een `challenge_id` waarmee de browser het resultaat terugbrengt. De
  bestaande passkeys gaan mee als `excludeCredentials`, zodat een authenticator
  die al geregistreerd is dat zelf weigert in plaats van een dubbele rij op te
  leveren.
  """
  def start_passkey_registration(%User{} = user) do
    challenge =
      Wax.new_registration_challenge(
        origin: passkey_origin(),
        rp_id: :auto,
        attestation: "none",
        user_verification: "preferred",
        timeout: @passkey_timeout_seconds
      )

    id = PasskeyChallenges.put(challenge, %{user_id: user.id, purpose: :register})

    %{
      challenge_id: id,
      public_key: %{
        challenge: Base.url_encode64(challenge.bytes, padding: false),
        rp: %{name: "Bunk Hosting", id: challenge.rp_id},
        user: %{
          id: Base.url_encode64(user.id, padding: false),
          name: user.email,
          displayName: user.name || user.email
        },
        pubKeyCredParams: [%{type: "public-key", alg: -7}, %{type: "public-key", alg: -257}],
        timeout: @passkey_timeout_seconds * 1000,
        attestation: "none",
        authenticatorSelection: %{residentKey: "preferred", userVerification: "preferred"},
        excludeCredentials:
          for p <- list_passkeys(user) do
            %{type: "public-key", id: Base.url_encode64(p.credential_id, padding: false)}
          end
      }
    }
  end

  @doc """
  Rondt een registratie af met het antwoord van de authenticator.

  `attestation_object` en `client_data_json` zijn de rauwe bytes uit de browser
  (al base64url-gedecodeerd door de controller). De challenge is eenmalig: ook
  bij een fout antwoord is hij daarna weg.
  """
  def finish_passkey_registration(%User{} = user, challenge_id, attrs) do
    with {:ok, challenge, %{user_id: uid, purpose: :register}} <-
           PasskeyChallenges.take(challenge_id),
         true <- uid == user.id,
         {:ok, {auth_data, _attestation}} <-
           wax(fn -> Wax.register(attrs.attestation_object, attrs.client_data_json, challenge) end) do
      cred = auth_data.attested_credential_data

      %Passkey{}
      |> Passkey.changeset(%{
        user_id: user.id,
        credential_id: cred.credential_id,
        public_key: Passkey.encode_cose_key(cred.credential_public_key),
        sign_count: auth_data.sign_count,
        label: attrs.label
      })
      |> Repo.insert()
    else
      :error -> {:error, :challenge_expired}
      false -> {:error, :challenge_expired}
      # Een challenge die voor inloggen is uitgegeven. Zonder deze tak viel hij
      # door alle andere heen en werd het een WithClauseError: een 500 op een
      # verzoek dat iedere ingelogde gebruiker kan sturen.
      {:ok, _challenge, _meta} -> {:error, :challenge_expired}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      {:error, _wax} -> {:error, :invalid_passkey}
    end
  end

  @doc """
  Verwijdert een passkey, maar alleen als hij van deze gebruiker is en het
  huidige wachtwoord klopt.

  Een passkey kan de tweede factor van het account zijn. Met alleen een sessie
  -- een meegelezen cookie, een onbeheerde laptop -- kon iemand hem weghalen en
  daarmee de 2FA uitzetten, terwijl TOTP uitzetten wel een code vraagt. Het
  wachtwoord en geen TOTP-code, want een account met alleen passkeys heeft geen
  code; een wachtwoord heeft iedereen. Zelfde controle en zelfde slot als bij
  wachtwoord wijzigen.

  Eerst het wachtwoord, dan pas de opzoeking: zonder het juiste wachtwoord zegt
  het antwoord ook niets over welke passkey-id's er bestaan.
  """
  def delete_passkey(%User{id: user_id} = user, passkey_id, huidig) when is_binary(huidig) do
    with :ok <- Accounts.herbevestig_wachtwoord(user, huidig),
         %Passkey{} = p <- Repo.get_by(Passkey, id: passkey_id, user_id: user_id) do
      Repo.delete(p)
    else
      nil -> {:error, :not_found}
      {:error, :invalid_current_password} = fout -> fout
    end
  end

  @doc """
  Geeft een inlog-challenge uit voor een gebruiker die al met wachtwoord is
  geverifieerd. Nil als hij geen passkeys heeft: dan is er niets aan te bieden.
  """
  def start_passkey_login(%User{} = user) do
    case list_passkeys(user) do
      [] ->
        nil

      keys ->
        challenge =
          Wax.new_authentication_challenge(
            origin: passkey_origin(),
            rp_id: :auto,
            user_verification: "preferred",
            timeout: @passkey_timeout_seconds
          )

        id = PasskeyChallenges.put(challenge, %{user_id: user.id, purpose: :login})

        %{
          challenge_id: id,
          public_key: %{
            challenge: Base.url_encode64(challenge.bytes, padding: false),
            rpId: challenge.rp_id,
            timeout: @passkey_timeout_seconds * 1000,
            userVerification: "preferred",
            allowCredentials:
              for p <- keys do
                %{type: "public-key", id: Base.url_encode64(p.credential_id, padding: false)}
              end
          }
        }
    end
  end

  @doc """
  Controleert een assertie tegen de passkeys van deze gebruiker.

  Slaagt alleen als de handtekening klopt voor een sleutel die bij dit account
  hoort en de challenge nog geldig en ongebruikt was. Werkt de tekenteller bij;
  een teller die terugloopt wijst op een gekloonde sleutel en wordt geweigerd.
  """
  def finish_passkey_login(%User{} = user, challenge_id, attrs) do
    with {:ok, challenge, %{user_id: uid, purpose: :login}} <-
           PasskeyChallenges.take(challenge_id),
         true <- uid == user.id,
         %Passkey{} = pk <-
           Repo.get_by(Passkey, credential_id: attrs.credential_id, user_id: user.id),
         {:ok, auth_data} <-
           wax(fn ->
             Wax.authenticate(
               attrs.credential_id,
               attrs.authenticator_data,
               attrs.signature,
               attrs.client_data_json,
               challenge,
               [{pk.credential_id, Passkey.cose_key(pk)}]
             )
           end),
         :ok <- check_sign_count(pk, auth_data.sign_count) do
      pk
      |> Ecto.Changeset.change(sign_count: auth_data.sign_count, last_used_at: Clock.now())
      |> Repo.update()
    else
      :error -> {:error, :challenge_expired}
      false -> {:error, :challenge_expired}
      # Een registratie-challenge die als inlog-challenge wordt aangeboden: zie
      # finish_passkey_registration/3, zelfde gat, hier op het inlogpad.
      {:ok, _challenge, _meta} -> {:error, :challenge_expired}
      nil -> {:error, :invalid_passkey}
      {:error, :cloned} -> {:error, :invalid_passkey}
      {:error, _} -> {:error, :invalid_passkey}
    end
  end

  # wax geeft {:error, _} terug op een verkeerde handtekening, maar raist op
  # invoer die niet eens de vorm heeft van een WebAuthn-antwoord: verkeerde
  # base64, ontbrekende JSON-sleutels, geen CBOR. Dat is precies wat een
  # aanvaller of een kapotte client stuurt, en een inlog-endpoint mag daar niet
  # op crashen. Alles wat uit wax ontsnapt wordt hier één ongeldige poging.
  defp wax(fun) do
    fun.()
  rescue
    _ -> {:error, :invalid_passkey}
  end

  # Een authenticator die tellers ondersteunt telt strikt op. Twee apparaten met
  # dezelfde sleutel lopen uit de pas, en dat zie je hier: de teller die
  # binnenkomt is niet hoger dan de laatste. Alleen als BEIDE nul zijn is er geen
  # teller en valt er niets te vergelijken (WebAuthn §7.2, stap 21).
  #
  # Eerst moest de binnenkomende teller ook boven nul zijn. Dan kwam een kloon
  # die 0 meestuurde er altijd door, en omdat die 0 daarna werd opgeslagen stond
  # de controle voor die sleutel voorgoed uit.
  defp check_sign_count(%Passkey{sign_count: stored}, incoming)
       when (incoming > 0 or stored > 0) and incoming <= stored,
       do: {:error, :cloned}

  defp check_sign_count(_pk, _incoming), do: :ok

  # De origin is de exacte URL die de browser ziet. Zonder die gelijkheid
  # weigert wax terecht: een passkey voor app.bunkhosting.nl mag niet op een
  # ander domein werken.
  defp passkey_origin do
    Application.get_env(:control_plane, :public_url) || "http://localhost:4000"
  end
end
