defmodule ControlPlane.Accounts do
  @moduledoc """
  User identity and authentication for the control-plane API.

  Handles registration (pbkdf2 password hashing), email + password login with
  constant-time comparison, and bearer session tokens. Session tokens are stored
  hashed at rest — see `ControlPlane.Accounts.UserToken` — and the raw token is
  returned to the caller exactly once at generation time.
  """
  import Ecto.Query, warn: false

  require Logger

  alias ControlPlane.Accounts.BreachedPasswords
  alias ControlPlane.Accounts.Deletion
  alias ControlPlane.Accounts.LoginThrottle
  alias ControlPlane.Accounts.Passkeys
  alias ControlPlane.Accounts.Totp
  alias ControlPlane.Accounts.User
  alias ControlPlane.Accounts.UserToken
  alias ControlPlane.Clock
  alias ControlPlane.Credits
  alias ControlPlane.Metrics
  alias ControlPlane.Notifier
  alias ControlPlane.RateLimiter
  alias ControlPlane.Repo

  @doc """
  Fetches a user by id, raising `Ecto.NoResultsError` if none exists.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Looks up a user by email (citext, case-insensitive). Returns nil if none."
  def get_user_by_email(email) when is_binary(email), do: Repo.get_by(User, email: email)

  @doc "Looks up a user by id, or nil if not found."
  def get_user(id), do: Repo.get(User, id)

  ## TOTP multi-factor authentication

  @doc "Zie `ControlPlane.Accounts.Totp.totp_active?/1`."
  defdelegate totp_active?(user), to: Totp

  @doc "Zie `ControlPlane.Accounts.Totp.start_totp_setup/1`."
  defdelegate start_totp_setup(user), to: Totp

  @doc "Zie `ControlPlane.Accounts.Totp.confirm_totp/2`."
  defdelegate confirm_totp(user, code), to: Totp

  @doc "Zie `ControlPlane.Accounts.Totp.disable_totp/1`."
  defdelegate disable_totp(user), to: Totp

  @doc "Zie `ControlPlane.Accounts.Totp.valid_totp?/2`."
  defdelegate valid_totp?(user, code), to: Totp

  @doc "Zie `ControlPlane.Accounts.Totp.totp_uri/1`."
  defdelegate totp_uri(user), to: Totp

  @doc "Zie `ControlPlane.Accounts.Totp.totp_secret_base32/1`."
  defdelegate totp_secret_base32(user), to: Totp

  @doc """
  Registers a new user from `attrs` (`email`, `password`, optionally `name`/`role`).

  Returns `{:ok, user}` or `{:error, changeset}` (e.g. duplicate email, short
  password). The signup bonus is granted on email confirmation (`confirm_user/1`),
  NOT here — crediting it at registration is what let a throwaway, unverified
  address farm free wallet balance.
  """
  def register_user(attrs) do
    changeset = %User{} |> User.registration_changeset(attrs) |> weiger_gelekt(attrs)

    case Repo.insert(changeset) do
      {:ok, user} = ok ->
        deliver_user_confirmation_instructions(user)
        ok

      error ->
        error
    end
  end

  # Een wachtwoord dat al in een datalek staat is te raden, hoe lang het ook is.
  # Alleen als de rest van de changeset klopt: een wachtwoord van vier tekens is
  # al afgekeurd en hoeft geen verzoek naar buiten te veroorzaken.
  defp weiger_gelekt(changeset, attrs) do
    wachtwoord = attrs["password"] || Map.get(attrs, :password)

    if changeset.valid? and is_binary(wachtwoord) and BreachedPasswords.breached?(wachtwoord) do
      Ecto.Changeset.add_error(
        changeset,
        :password,
        "komt voor in een bekend datalek en is daarmee te raden; kies een ander"
      )
    else
      changeset
    end
  end

  ## Email-link tokens

  # Both email-link flows (confirmation and password reset) are the same four
  # steps, and the steps are only safe in this order: invalidate the older
  # tokens of that context BEFORE minting a new one, so a mailbox never holds
  # two live links and the user can trust that requesting a new link kills the
  # old one. Keeping the sequence in one place is what stops the two flows from
  # drifting — a fix applied to one and forgotten in the other is precisely how
  # a link the system considers revoked stays usable.
  #
  # `deliver` is the `Notifier` entry point for that context, arity 2
  # (user, encoded_token). Mail delivery failures are the Notifier's business;
  # the token is already persisted by then, so the user can always ask for a
  # resend. Returns {:ok, encoded_token} — the raw token exists only here and in
  # the email, never in the database.
  # How many of one kind of link a single account may be sent per hour. Generous
  # for a person who did not get the first one and clicks again; useless to
  # anyone hammering the endpoint.
  @mail_per_hour 5

  defp issue_email_token(%User{} = user, context, deliver) when is_function(deliver, 2) do
    # Checked BEFORE anything is written: a refused send must not invalidate the
    # link the person is already holding.
    #
    # The cap lives here rather than on a route because every path that mails a
    # customer comes through this function, and because the damage is not to the
    # endpoint. Thousands of messages from one sender in a minute is how a mail
    # provider decides this domain is a spammer — and then nobody gets a
    # confirmation, a reset, or an ops alert until someone notices and argues us
    # back off a blocklist.
    if RateLimiter.hit("mail:#{context}:#{user.id}", @mail_per_hour, :timer.hours(1)) == :ok do
      Repo.delete_all(UserToken.by_user_and_contexts_query(user, [context]))
      {encoded_token, user_token} = UserToken.build_email_token(user, context)
      Repo.insert!(user_token)
      deliver.(user, encoded_token)
      {:ok, encoded_token}
    else
      # Reported as success on purpose. The caller must learn nothing from this —
      # the reset endpoint answers identically for every address precisely so it
      # cannot be used to find out who has an account here — and the person has
      # already been sent a link that still works.
      Logger.info(
        "mail throttled: #{context} for a user who already had #{@mail_per_hour} this hour"
      )

      {:ok, :throttled}
    end
  end

  ## Email confirmation

  @doc """
  Mints a fresh single-use confirmation token for `user` and emails it. Any
  earlier unconsumed confirmation token for this user is invalidated first, so
  only the most recently sent link works (resending a confirmation email must
  not leave two live links).

  A no-op returning `{:error, :already_confirmed}` for an already-confirmed user
  — resending a confirmation link (or a delayed double-click on "resend") must
  never re-grant the signup bonus or re-send a stale email.
  """
  def deliver_user_confirmation_instructions(%User{confirmed_at: confirmed})
      when not is_nil(confirmed),
      do: {:error, :already_confirmed}

  def deliver_user_confirmation_instructions(%User{} = user),
    do: issue_email_token(user, "confirm", &Notifier.deliver_confirmation_instructions/2)

  @doc """
  Confirms a user from a raw confirmation `token`, atomically stamping
  `confirmed_at`, burning every outstanding confirm token for that user (so the
  same link can't be replayed), and granting the one-time signup bonus — all in
  one transaction so a crediting failure can never leave the account confirmed
  without its bonus, or vice versa.

  Returns `{:ok, user}`, or one of two distinct failures — they are NOT
  interchangeable and callers are expected to treat them differently:

    * `{:error, :invalid_token}` — the link itself is malformed, unknown,
      already used, or expired. The user can fix this by requesting a new one.
    * `{:error, :confirmation_failed}` — the token was good but the write did
      not go through (database trouble, a failing signup-bonus grant, …). The
      account is untouched and the link still works; the fault is ours, it is
      logged at `:error`, and the user should simply retry.

  Collapsing the second case into `:invalid_token` (as this used to) told the
  user their link had expired, sent them chasing a fresh link that would fail
  the same way, and left the real fault silent in the logs.
  """
  def confirm_user(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query) do
      confirm_changeset =
        Ecto.Changeset.change(user, confirmed_at: Clock.now())

      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, confirm_changeset)
      |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, ["confirm"]))
      |> Ecto.Multi.run(:bonus, fn _repo, %{user: confirmed_user} ->
        Credits.grant_signup_bonus(confirmed_user.id)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: confirmed_user}} ->
          {:ok, confirmed_user}

        {:error, step, reason, _changes} ->
          Logger.error(
            "confirm_user/1 failed for user #{user.id} at #{inspect(step)}: #{inspect(reason)}"
          )

          {:error, :confirmation_failed}
      end
    else
      _ -> {:error, :invalid_token}
    end
  end

  def confirm_user(_token), do: {:error, :invalid_token}

  ## Password reset

  @doc """
  Mints a single-use password-reset token for `user` and emails it, invalidating
  any earlier unconsumed reset token first (so requesting a new link kills the
  old one). Returns `{:ok, encoded_token}` — see `request_password_reset/1` for
  the enumeration-safe entry point callers should actually use; this function's
  caller learns whether the account exists (only appropriate once you already
  hold a `%User{}`, e.g. an admin-initiated reset).
  """
  def deliver_user_reset_password_instructions(%User{} = user),
    do: issue_email_token(user, "reset_password", &Notifier.deliver_reset_password_instructions/2)

  @doc """
  Enumeration-safe entry point for "forgot password": looks up `email` and, if
  found, sends a reset link.

  ALWAYS returns `:ok` — for a known address, an unknown one, and a value that
  isn't even a string. That uniform answer is the whole point of the function
  and must survive any future edit: the caller (the public
  `POST /auth/password-reset` endpoint) renders its response straight from this
  result, so the moment a "no such user" leaks out here, the endpoint becomes an
  oracle for which email addresses hold an account.

  Callers that legitimately need to know whether delivery happened already hold
  a `%User{}` and should call `deliver_user_reset_password_instructions/1`.
  """
  def request_password_reset(email) when is_binary(email) do
    case get_user_by_email(String.downcase(email)) do
      %User{} = user ->
        # The delivery result is dropped on purpose — see the docstring. It is
        # never allowed to reach the caller, not even as a success signal.
        _ = deliver_user_reset_password_instructions(user)
        :ok

      nil ->
        :ok
    end
  end

  def request_password_reset(_email), do: :ok

  @doc """
  Returns the user for a valid, unexpired, unused password-reset `token`, or
  `nil`.
  """
  def get_user_by_reset_password_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  def get_user_by_reset_password_token(_token), do: nil

  @doc """
  Resets `user`'s password to `attrs["password"]` and, in the same transaction,
  burns the reset token AND every session token (a password reset is exactly the
  "I think someone else has my credentials" moment — leaving old sessions alive
  would defeat the point). Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def reset_user_password(%User{} = user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs) |> weiger_gelekt(attrs))
    |> Ecto.Multi.delete_all(
      :tokens,
      UserToken.by_user_and_contexts_query(user, ["reset_password", "session"])
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Wijzigt het wachtwoord van iemand die al is ingelogd.

  Het huidige wachtwoord moet er expliciet bij. Een geldige sessie is hier niet
  genoeg bewijs: wie een sessie in handen krijgt -- een meegelezen cookie, een
  onbeheerde laptop -- mag daarmee niet het account overnemen door het
  wachtwoord te wijzigen. Dit is precies de handeling waarvoor je opnieuw wilt
  weten dat het de eigenaar zelf is.

  Alle andere sessies vallen om, die van de aanvrager blijft staan. Wie zijn
  wachtwoord wijzigt omdat hij vermoedt dat iemand meekijkt, wordt daar niet
  voor uitgelogd -- maar de meekijker wel.
  """
  @spec change_user_password(User.t(), String.t(), map(), binary() | nil) ::
          {:ok, User.t()} | {:error, :invalid_current_password | Ecto.Changeset.t()}
  def change_user_password(%User{} = user, huidig, attrs, behoud_token \\ nil) do
    with :ok <- herbevestig_wachtwoord(user, huidig) do
      wijzig_wachtwoord(user, attrs, behoud_token)
    end
  end

  # Het huidige wachtwoord als herbevestiging, voor handelingen die een geldige
  # sessie alleen niet mag kunnen doen.
  #
  # Hetzelfde slot als bij inloggen, en bewust dezelfde teller: het is hetzelfde
  # wachtwoord dat geraden wordt. Zonder dit is elke endpoint die hierom vraagt
  # de stille achterdeur om er ongelimiteerd op te gokken met een sessie die je
  # al hebt.
  #
  # Publiek omdat `ControlPlane.Accounts.Passkeys.delete_passkey/3` hem ook
  # gebruikt; geen onderdeel van de API.
  @doc false
  def herbevestig_wachtwoord(%User{} = user, huidig) do
    cond do
      LoginThrottle.blocked?(user.email) ->
        {:error, :invalid_current_password}

      not User.valid_password?(user, huidig) ->
        LoginThrottle.note_failure(user.email)
        {:error, :invalid_current_password}

      true ->
        :ok
    end
  end

  defp wijzig_wachtwoord(%User{} = user, attrs, behoud_token) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs) |> weiger_gelekt(attrs))
    |> Ecto.Multi.delete_all(:tokens, andere_sessies(user, behoud_token))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: bijgewerkt}} -> {:ok, bijgewerkt}
      {:error, :user, changeset, _changes} -> {:error, changeset}
    end
  end

  defp andere_sessies(%User{} = user, nil) do
    UserToken.by_user_and_contexts_query(user, ["session"])
  end

  # Tokens staan gehasht in de database; het token uit het verzoek is de ruwe
  # waarde. Zonder die hash matcht de vergelijking nooit en valt ook de eigen
  # sessie om -- wat werkt als "overal uitloggen" en niet als wat hier staat.
  defp andere_sessies(%User{} = user, behoud_token) do
    hash = UserToken.hashed(behoud_token)

    from t in UserToken.by_user_and_contexts_query(user, ["session"]),
      where: t.token != ^hash
  end

  @doc """
  Sets a user's `role` (`:user`/`:admin`).

  This is the authorized, server-side role-elevation path deliberately kept out of
  the registration changeset (a registrant can never request a role) — an admin
  promotes a user to `:admin` here. Returns `{:ok, user}`.
  """
  def update_user_role(%User{} = user, role) when role in [:user, :admin] do
    user
    |> Ecto.Changeset.change(role: role)
    |> Repo.update()
  end

  @doc """
  Returns the user matching `email`/`password`, or `nil`.

  Runs in (near) constant time whether or not the email exists: when no user is
  found, a dummy pbkdf2 verification is still performed via
  `User.valid_password?/2`.
  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    # Throttled accounts are told exactly what a wrong password is told. Both the
    # JSON API and the browser form come through here, so this is the one place
    # the check has to be.
    if LoginThrottle.blocked?(email), do: nil, else: verify_password(email, password)
  end

  def get_user_by_email_and_password(_email, _password), do: nil

  defp verify_password(email, password) do
    user = Repo.get_by(User, email: String.downcase(email))

    # valid_password?/2 hashes against a dummy when `user` is nil, so an address
    # that exists and one that does not take the same time to reject.
    if User.valid_password?(user, password) do
      LoginThrottle.clear(email)
      Metrics.count(:successes)
      user
    else
      note_failed_login(email)
      Metrics.count(:failures)
      nil
    end
  end

  defp note_failed_login(email) do
    failures = LoginThrottle.note_failure(email)

    # Worth a line in the log: a single account collecting failures from many
    # addresses is credential stuffing, and nothing else in the system can see it.
    if failures in [5, 10, 20],
      do: Logger.warning("login throttle: #{failures} failed attempts against an account")

    :ok
  end

  @doc """
  Generates a new session token for `user`, persists its hash, and returns the raw
  token (the only copy ever returned to the caller).
  """
  def generate_user_session_token(user, opts \\ []) do
    {token, user_token} = UserToken.build_session_token(user, Keyword.get(opts, :mfa, false))
    Repo.insert!(user_token)
    token
  end

  @doc """
  Of de sessie bij `token` haar tweede factor heeft laten zien.

  Iets anders dan `has_second_factor?/1`: dat zegt of het ACCOUNT er een heeft.
  Een sessie die met alleen een wachtwoord begon, blijft dat, ook als de
  gebruiker daarna in die sessie 2FA aanzet.
  """
  @spec session_mfa?(binary()) :: boolean()
  def session_mfa?(token) when is_binary(token) do
    hashed = UserToken.hashed(token)

    Repo.exists?(
      from t in UserToken,
        where: t.token == ^hashed and t.context == "session" and not is_nil(t.mfa_at)
    )
  end

  def session_mfa?(_token), do: false

  @doc "Zie `ControlPlane.Accounts.Deletion.delete_or_anonymise_user/1`."
  defdelegate delete_or_anonymise_user(user), to: Deletion

  @doc "Zie `ControlPlane.Accounts.Deletion.has_live_vpses?/1`."
  defdelegate has_live_vpses?(user), to: Deletion

  @doc "Zie `ControlPlane.Accounts.Deletion.has_financial_history?/1`."
  defdelegate has_financial_history?(user), to: Deletion

  @doc """
  Of dit account meer dan een wachtwoord nodig heeft om binnen te komen.

  Een passkey telt net zo goed als een authenticator-app: een passkey is aan het
  domein gebonden en daarmee bestand tegen phishing, dus daarnaast ook nog TOTP
  eisen zou strenger lijken en niets toevoegen.
  """
  @spec has_second_factor?(User.t()) :: boolean()
  def has_second_factor?(%User{totp_confirmed_at: %DateTime{}}), do: true

  def has_second_factor?(%User{} = user), do: Passkeys.passkeys_active?(user)

  def has_second_factor?(_), do: false

  @doc "Zie `ControlPlane.Accounts.Deletion.owns_nodes?/1`."
  defdelegate owns_nodes?(user), to: Deletion

  @doc """
  Returns the user owning a valid, non-expired session `token`, or `nil`.

  Elke geslaagde lookup houdt de sessie levend: zolang iemand het paneel gebruikt
  schuift de stiltegrens mee. Dat gebeurt hooguit eens per kwartier, zodat de
  tabel die elke request leest niet ook elke request beschreven wordt.
  """
  def get_user_by_session_token(token) when is_binary(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)

    case Repo.one(query) do
      nil ->
        nil

      {user, user_token} ->
        touch_session(user_token)
        user
    end
  end

  def get_user_by_session_token(_token), do: nil

  defp touch_session(user_token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if UserToken.needs_touch?(user_token.last_used_at, now) do
      # Zonder where op de oude waarde zouden twee gelijktijdige requests elkaar
      # overschrijven. Dat is onschuldig, maar het is ook gratis te vermijden.
      from(t in UserToken, where: t.id == ^user_token.id)
      |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  end

  @doc """
  Ruimt sessies op die verlopen zijn — op leeftijd of op stilte.

  Verlopen rijen doen al niets meer (de query weigert ze), dus dit is opruimen,
  geen beveiliging. Het houdt de tabel klein en zorgt dat een overzicht van
  actieve sessies niet langer is dan de waarheid.
  """
  @spec purge_expired_sessions() :: non_neg_integer()
  def purge_expired_sessions do
    {count, _} = Repo.delete_all(UserToken.expired_sessions_query())
    count
  end

  @doc "De grenzen waarbinnen een sessie geldig blijft."
  defdelegate session_limits(), to: UserToken

  @doc """
  Deletes the session identified by `token`. Always returns `:ok`.
  """
  def delete_user_session_token(token) when is_binary(token) do
    hashed_token = :crypto.hash(:sha256, token)
    Repo.delete_all(UserToken.by_token_and_context_query(hashed_token, "session"))
    :ok
  end

  def delete_user_session_token(_token), do: :ok

  @doc """
  Revokes all of `user`'s session tokens ("log out everywhere"). Use this as the
  kill switch for a leaked token and on any future password change. Always `:ok`.
  """
  def delete_all_user_session_tokens(%User{} = user) do
    Repo.delete_all(UserToken.by_user_and_contexts_query(user, ["session"]))
    :ok
  end

  ## Passkeys (WebAuthn)

  @doc "Zie `ControlPlane.Accounts.Passkeys.passkeys_active?/1`."
  defdelegate passkeys_active?(user), to: Passkeys

  @doc "Zie `ControlPlane.Accounts.Passkeys.list_passkeys/1`."
  defdelegate list_passkeys(user), to: Passkeys

  @doc "Zie `ControlPlane.Accounts.Passkeys.start_passkey_registration/1`."
  defdelegate start_passkey_registration(user), to: Passkeys

  @doc "Zie `ControlPlane.Accounts.Passkeys.finish_passkey_registration/3`."
  defdelegate finish_passkey_registration(user, challenge_id, attrs), to: Passkeys

  @doc "Zie `ControlPlane.Accounts.Passkeys.delete_passkey/3`."
  defdelegate delete_passkey(user, passkey_id, huidig), to: Passkeys

  @doc "Zie `ControlPlane.Accounts.Passkeys.start_passkey_login/1`."
  defdelegate start_passkey_login(user), to: Passkeys

  @doc "Zie `ControlPlane.Accounts.Passkeys.finish_passkey_login/3`."
  defdelegate finish_passkey_login(user, challenge_id, attrs), to: Passkeys
end
