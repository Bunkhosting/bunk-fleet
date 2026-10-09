defmodule ControlPlane.Accounts.UserToken do
  @moduledoc """
  A bearer session token tying an authenticated request back to a `User`.

  A raw 32-byte random token is generated and handed to the client once; only its
  SHA-256 hash is persisted (in the `token` column) so a database leak cannot be
  replayed.

  A session ends in one of two ways: it reaches `@session_validity_in_days` days
  after being handed out, or it sits unused for `@idle_timeout_in_days` days.
  The second one does the real work. A token that leaks is usually replayed days
  later, and an absolute window alone would keep honouring it for the rest of its
  term; going stale on silence closes that door without logging out someone who
  is actually using the panel.
  """
  use Ecto.Schema
  import Ecto.Query

  alias ControlPlane.Accounts.User
  alias ControlPlane.Accounts.UserToken

  @hash_algorithm :sha256
  @rand_size 32

  @session_validity_in_days 30
  @idle_timeout_in_days 7

  # Iedere request het tijdstip bijwerken zou een schrijfactie per request
  # betekenen op de tabel die ook elke request leest. Een kwartier speling kost
  # niets aan veiligheid — de drempel is dagen — en scheelt vrijwel alle writes.
  @touch_after_seconds 900

  @doc "Hoe lang een sessie hooguit meegaat, en hoe lang hij ongebruikt mag zijn."
  @spec session_limits() :: %{max_days: pos_integer(), idle_days: pos_integer()}
  def session_limits, do: %{max_days: @session_validity_in_days, idle_days: @idle_timeout_in_days}

  @doc "Of `last_used_at` ver genoeg in het verleden ligt om te herschrijven."
  @spec needs_touch?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def needs_touch?(nil, _now), do: true

  def needs_touch?(last_used_at, now),
    do: DateTime.diff(now, last_used_at) >= @touch_after_seconds

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :last_used_at, :utc_datetime
    # Wanneer deze sessie haar tweede factor liet zien; nil = nooit. Zie
    # Plugs.RequireAdminMfa.
    field :mfa_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  De vorm waarin een token in de database staat: de hash, nooit het token zelf.

  Wie een rij wil vergelijken met een token uit een verzoek moet dit gebruiken.
  Het algoritme staat op één plek omdat een tweede `:crypto.hash(:sha256, ...)`
  ergens anders precies is hoe zoiets uit elkaar groeit -- en een vergelijking
  die stilletjes nooit matcht valt niet op: hij doet gewoon te veel.
  """
  @spec hashed(binary()) :: binary()
  def hashed(token), do: :crypto.hash(@hash_algorithm, token)

  @doc """
  Builds a session token and its (unpersisted) struct.

  Returns `{raw_token, user_token}` where `raw_token` is the value handed to the
  client and `user_token.token` is its SHA-256 hash, ready to be inserted.
  """
  def build_session_token(user, mfa? \\ false) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {token,
     %UserToken{
       token: hashed_token,
       context: "session",
       user_id: user.id,
       last_used_at: now,
       mfa_at: if(mfa?, do: now)
     }}
  end

  @doc """
  Query that fetches the `User` and the token row for a still-valid session.

  `token` is the raw token; it is hashed before lookup so it matches what is
  stored. Both windows are checked here rather than in the caller: a session that
  is too old, or too long untouched, must not resolve to a user at all.
  """
  def verify_session_token_query(token) do
    hashed_token = :crypto.hash(@hash_algorithm, token)

    query =
      from token in by_token_and_context_query(hashed_token, "session"),
        join: user in assoc(token, :user),
        where:
          token.inserted_at > ago(@session_validity_in_days, "day") and
            token.last_used_at > ago(@idle_timeout_in_days, "day"),
        select: {user, token}

    {:ok, query}
  end

  @doc """
  Query over session rows that neither window can still save.

  Used by the periodic sweep: keeping dead rows around costs an index and makes
  "where am I logged in" longer than it is true.
  """
  def expired_sessions_query do
    from t in UserToken,
      where:
        t.context == "session" and
          (t.inserted_at <= ago(@session_validity_in_days, "day") or
             t.last_used_at <= ago(@idle_timeout_in_days, "day"))
  end

  # Email-link tokens: "confirm" (registration) and "reset_password". Unlike
  # session tokens these are single-use — the caller deletes the row once
  # consumed (see ControlPlane.Accounts) — and URL-safe-base64 encoded (not raw
  # bytes) because they travel inside a mailto link's query string.
  @email_token_validity_seconds %{
    # 24h to confirm a fresh registration.
    "confirm" => 60 * 60 * 24,
    # 1h for a password-reset link — short-lived because a leaked link (mail
    # provider log, forwarded email, shoulder surfing) directly resets a password.
    "reset_password" => 60 * 60
  }

  @doc """
  Builds a single-use email-link token for `context` ("confirm" or
  "reset_password"). Returns `{url_safe_token, %UserToken{}}` — the raw token is
  the only copy ever handed to the caller; only its hash is persisted.
  """
  def build_email_token(%User{} = user, context)
      when is_map_key(@email_token_validity_seconds, context) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %UserToken{token: hashed_token, context: context, user_id: user.id}}
  end

  @doc """
  Query that fetches the `User` for a non-expired, single-use `context` token.

  `token` is the URL-safe-base64 string handed out by `build_email_token/2`.
  Returns `{:ok, query}` (matching zero or one row — `Repo.one/1` it) on a
  well-formed token, or `:error` if it doesn't even decode.
  """
  def verify_email_token_query(token, context)
      when is_map_key(@email_token_validity_seconds, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        validity_seconds = Map.fetch!(@email_token_validity_seconds, context)

        query =
          from t in by_token_and_context_query(hashed_token, context),
            join: user in assoc(t, :user),
            where: t.inserted_at > ago(^validity_seconds, "second"),
            select: user

        {:ok, query}

      :error ->
        :error
    end
  end

  @doc """
  Query that matches a stored (hashed) token within a given context.
  """
  def by_token_and_context_query(hashed_token, context) do
    from UserToken, where: [token: ^hashed_token, context: ^context]
  end

  @doc """
  Query for all tokens belonging to `user` in the given `contexts` (or `:all`).
  """
  def by_user_and_contexts_query(user, :all) do
    from t in UserToken, where: t.user_id == ^user.id
  end

  def by_user_and_contexts_query(user, [_ | _] = contexts) do
    from t in UserToken, where: t.user_id == ^user.id and t.context in ^contexts
  end
end
