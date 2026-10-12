defmodule ControlPlane.SoftwareAuthenticator do
  @moduledoc """
  Een passkey-authenticator in software, voor tests van de WebAuthn-ceremonie.

  Een echte passkey zit in een telefoon of een beveiligingssleutel, en die is in
  een testsuite niet aan te sturen. Wat de server te zien krijgt is echter
  gewoon bytes: een `clientDataJSON` die de browser opstelt, `authenticatorData`
  van de authenticator, en bij inloggen een ECDSA-handtekening over die twee.
  Deze module bouwt die bytes zelf, met een echte P-256-sleutel (ES256, COSE-alg
  -7), zodat een geldige ceremonie echt door wax komt en een manipulatie op een
  echte controle strandt -- en niet op een kapotte testopzet.

  De attestatie heeft het formaat `none`. Dat vraagt de server ook
  (`attestation: "none"`), en het is wat de meeste passkeys in de praktijk
  sturen.

  Manipulaties gaan via opties, zodat een negatieve test precies dezelfde opbouw
  gebruikt als zijn tegenproef en alleen in dat ene veld verschilt:

    * `:type` -- het `type` in clientDataJSON
    * `:challenge` -- de challenge-bytes in clientDataJSON (rauw, niet base64)
    * `:origin` -- de origin in clientDataJSON
    * `:rp_id` -- het domein waarvan de hash in authenticatorData staat
    * `:flags` -- de vlaggenbyte van authenticatorData
    * `:sign_count` -- de tekenteller (standaard 0: "geen teller")
    * `:fmt` -- het attestatieformaat (alleen bij registreren)
    * `:signer` -- een andere authenticator die de handtekening zet (alleen bij
      inloggen)

  Bewust geen CBOR-bibliotheek: de paar typen die hier nodig zijn staan
  hieronder uitgeschreven, zodat zichtbaar is welke bytes er de deur uit gaan.
  """

  defstruct [:credential_id, :private_key, :x, :y]

  @type t :: %__MODULE__{}

  # Vlaggen in authenticatorData (WebAuthn §6.1): 0x01 = gebruiker aanwezig (UP),
  # 0x04 = gebruiker geverifieerd (UV), 0x40 = er volgt een credential (AT, alleen
  # bij registreren). Wat een telefoon met vingerafdruk stuurt.
  @registratie_vlaggen 0x45
  @assertie_vlaggen 0x05

  @doc "Een authenticator met een verse P-256-sleutel en een willekeurig credential-id."
  @spec new() :: t()
  def new do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private_key} =
      :crypto.generate_key(:ecdh, :secp256r1)

    %__MODULE__{
      credential_id: :crypto.strong_rand_bytes(32),
      private_key: private_key,
      x: x,
      y: y
    }
  end

  @doc "De publieke sleutel als COSE-map, in de vorm waarin wax hem uit de attestatie haalt."
  @spec cose_key(t()) :: map()
  def cose_key(%__MODULE__{x: x, y: y}), do: %{1 => 2, 3 => -7, -1 => 1, -2 => x, -3 => y}

  @doc """
  De origin die de browser meestuurt: het publieke adres van het control plane,
  met dezelfde terugval als `Accounts`.
  """
  @spec origin() :: String.t()
  def origin, do: Application.get_env(:control_plane, :public_url) || "http://localhost:4000"

  @doc """
  Het antwoord op `navigator.credentials.create()`: `attestation_object` en
  `client_data_json` als rauwe bytes, zoals de controller ze na het
  base64url-decoderen aan `Accounts.finish_passkey_registration/3` geeft.

  `public_key` is de `public_key`-map uit de registratie-challenge, met atoom-
  of stringsleutels (`Accounts` geeft atomen, de API strings).
  """
  @spec registratie(t(), map(), keyword()) :: map()
  def registratie(%__MODULE__{} = auth, public_key, opts \\ []) do
    rp_id = Keyword.get_lazy(opts, :rp_id, fn -> public_key |> veld(:rp) |> veld(:id) end)

    # Attested credential data (WebAuthn §6.5.1): AAGUID (nullen, zoals bij
    # attestatie "none"), de lengte van het credential-id in twee bytes, het id
    # zelf en de publieke sleutel als COSE-CBOR.
    credential =
      <<0::128, byte_size(auth.credential_id)::16>> <>
        auth.credential_id <>
        cbor(%{1 => 2, 3 => -7, -1 => 1, -2 => {:bytes, auth.x}, -3 => {:bytes, auth.y}})

    auth_data =
      authenticator_data(
        rp_id,
        Keyword.get(opts, :flags, @registratie_vlaggen),
        Keyword.get(opts, :sign_count, 0)
      ) <> credential

    %{
      attestation_object:
        cbor(%{
          "fmt" => Keyword.get(opts, :fmt, "none"),
          "attStmt" => %{},
          "authData" => {:bytes, auth_data}
        }),
      client_data_json: client_data("webauthn.create", public_key, opts)
    }
  end

  @doc """
  Het antwoord op `navigator.credentials.get()`: credential-id,
  authenticatorData, handtekening en clientDataJSON als rauwe bytes, in de vorm
  die `Accounts.finish_passkey_login/3` verwacht.

  `public_key` is de `public_key`-map uit de inlog-challenge.
  """
  @spec assertie(t(), map(), keyword()) :: map()
  def assertie(%__MODULE__{} = auth, public_key, opts \\ []) do
    rp_id = Keyword.get_lazy(opts, :rp_id, fn -> veld(public_key, :rpId) end)

    auth_data =
      authenticator_data(
        rp_id,
        Keyword.get(opts, :flags, @assertie_vlaggen),
        Keyword.get(opts, :sign_count, 0)
      )

    client_data_json = client_data("webauthn.get", public_key, opts)
    signer = Keyword.get(opts, :signer, auth)

    # De handtekening gaat over authenticatorData gevolgd door de SHA-256 van de
    # clientDataJSON (WebAuthn §6.3.3). :crypto levert hem DER-gecodeerd, en dat
    # is ook wat een browser doorgeeft.
    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data_json),
        [signer.private_key, :secp256r1]
      )

    %{
      credential_id: auth.credential_id,
      authenticator_data: auth_data,
      signature: signature,
      client_data_json: client_data_json
    }
  end

  @doc "Een registratie zoals de browser hem als `credential` naar de API stuurt."
  @spec registratie_json(map()) :: map()
  def registratie_json(%{attestation_object: ao, client_data_json: cdj}) do
    %{"response" => %{"attestationObject" => b64(ao), "clientDataJSON" => b64(cdj)}}
  end

  @doc "Een assertie zoals de browser hem als `passkey` naar `POST /api/v1/auth/login` stuurt."
  @spec assertie_json(map(), String.t()) :: map()
  def assertie_json(assertie, challenge_id) do
    %{
      "challenge_id" => challenge_id,
      "id" => b64(assertie.credential_id),
      "response" => %{
        "authenticatorData" => b64(assertie.authenticator_data),
        "signature" => b64(assertie.signature),
        "clientDataJSON" => b64(assertie.client_data_json)
      }
    }
  end

  defp authenticator_data(rp_id, flags, sign_count),
    do: :crypto.hash(:sha256, rp_id) <> <<flags::8, sign_count::32>>

  defp client_data(type, public_key, opts) do
    challenge =
      case Keyword.fetch(opts, :challenge) do
        {:ok, bytes} -> bytes
        :error -> public_key |> veld(:challenge) |> Base.url_decode64!(padding: false)
      end

    Jason.encode!(%{
      "type" => Keyword.get(opts, :type, type),
      "challenge" => b64(challenge),
      "origin" => Keyword.get(opts, :origin, origin()),
      "crossOrigin" => false
    })
  end

  defp veld(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(map, Atom.to_string(key))
    end
  end

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)

  # Minimale CBOR-encoder (RFC 8949): precies de typen die een attestatie-object
  # en een COSE-sleutel gebruiken. Een Elixir-binary is een tekststring (major
  # type 3); een bytestring (major type 2) moet expliciet als {:bytes, b}.
  defp cbor(n) when is_integer(n) and n >= 0, do: kop(0, n)
  defp cbor(n) when is_integer(n), do: kop(1, -1 - n)
  defp cbor({:bytes, b}) when is_binary(b), do: kop(2, byte_size(b)) <> b
  defp cbor(s) when is_binary(s), do: kop(3, byte_size(s)) <> s

  defp cbor(m) when is_map(m) do
    paren = for {k, v} <- m, into: <<>>, do: cbor(k) <> cbor(v)
    kop(5, map_size(m)) <> paren
  end

  defp kop(major, n) when n < 24, do: <<major::3, n::5>>
  defp kop(major, n) when n < 0x100, do: <<major::3, 24::5, n::8>>
  defp kop(major, n) when n < 0x10000, do: <<major::3, 25::5, n::16>>
  defp kop(major, n), do: <<major::3, 26::5, n::32>>
end
