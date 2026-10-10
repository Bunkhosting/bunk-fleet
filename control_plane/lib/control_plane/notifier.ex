defmodule ControlPlane.Notifier do
  @moduledoc """
  Builds and sends every transactional email the platform emits: registration
  confirmation, password reset, and the low-balance warning sent when a
  subscription can't be charged. Delivery goes through `ControlPlane.Mailer`
  (Swoosh) — see its moduledoc for how the adapter varies per environment.

  Every message is multipart: the branded HTML body plus a plain-text
  alternative. The text part is not a formality — some clients render it by
  preference, and a mail with no text alternative scores worse with spam
  filters. Both bodies are rendered together by
  `ControlPlane.Notifier.Templates`, which returns `{text, html}` from a
  single call per email — see that module's moduledoc for why the two used
  to live apart (an inline heredoc here, a `.html.eex` there) and why that
  was a bug waiting to happen. This module no longer has any copy of its own
  to keep in sync: it asks `Templates` for both bodies and hands them to the
  mailer.

  Every `deliver_*/2` call is wrapped so a mail failure (SMTP down, misconfigured
  relay) never raises into the caller: registration, confirmation, and the
  billing settle loop must all complete regardless of whether the email actually
  went out. Failures are logged, not swallowed silently.

  ## Public API stability

  `deliver_confirmation_instructions/2`, `deliver_reset_password_instructions/2`,
  and `deliver_low_balance_warning/3` are called directly by
  `ControlPlane.Accounts` and `ControlPlane.Subscriptions`. Their names,
  arities, and `:ok | {:error, reason}` return shape are a contract with
  those callers and must not change here — only the rendering underneath
  them (this module's private `deliver/1` and `Templates`) is free to move.
  """
  require Logger

  alias ControlPlane.RateLimiter

  import Swoosh.Email

  alias ControlPlane.Accounts.User
  alias ControlPlane.Mailer
  alias ControlPlane.Notifier.Templates

  @doc "Sends the 'confirm your account' email with a link carrying `token`."
  def deliver_confirmation_instructions(%User{} = user, token) do
    url = public_url() <> "/verify-email?token=" <> token
    {text, html} = Templates.confirmation(user.name, url)

    deliver(%{
      to: user.email,
      subject: "Bevestig je Bunk Hosting account",
      text: text,
      html: html
    })
  end

  @doc "Sends the password-reset email with a link carrying `token`."
  def deliver_reset_password_instructions(%User{} = user, token) do
    url = public_url() <> "/reset-password?token=" <> token
    {text, html} = Templates.reset_password(user.name, url)

    deliver(%{
      to: user.email,
      subject: "Wachtwoord opnieuw instellen — Bunk Hosting",
      text: text,
      html: html
    })
  end

  @doc """
  Sends the "we couldn't charge your wallet" warning for `vps_name`, due again on
  `retry_date`. Sent when a subscription goes `:past_due` and its VPS is stopped.
  """
  def deliver_low_balance_warning(%User{} = user, vps_name, %Date{} = retry_date) do
    top_up_url = public_url() <> "/dashboard/billing"
    # Formatted once, then handed to both bodies via Templates.low_balance/4
    # so the text and HTML mail are guaranteed to show the same date string.
    retry_date_str = Calendar.strftime(retry_date, "%d-%m-%Y")
    {text, html} = Templates.low_balance(user.name, vps_name, retry_date_str, top_up_url)

    deliver(%{
      to: user.email,
      subject: "Saldo te laag — #{vps_name} is gepauzeerd",
      text: text,
      html: html
    })
  end

  @doc """
  True when there is an address for operational alerts to reach. Read at boot by
  `ControlPlane.SecurityPosture`, so an unset OPS_EMAIL is noticed before the
  alert that needed it.
  """
  def ops_email_configured? do
    case Application.get_env(:control_plane, :ops_email) do
      to when is_binary(to) and to != "" -> true
      _ -> false
    end
  end

  # Takes a map instead of four positional arguments: `to`/`subject`/`text`/`html`
  # are all strings, so a positional `deliver(to, subject, text, html)` reads
  # fine at the definition but is a silent transposition hazard at every call
  # site. Named keys make that class of mistake a `KeyError`/`FunctionClauseError`
  # instead of a wrong email going out.
  @doc """
  Mails the operator that something in the platform needs a person.

  Deliberately plain text and deliberately not branded: this goes to whoever runs
  Bunk, not to a customer, and it is read at the moment something is already
  wrong. The first line is the whole message; the body is evidence.

  Returns `{:error, :no_ops_email}` when `:ops_email` is unset, which is a
  configuration gap rather than a delivery failure — the caller (a systemd
  OnFailure unit) prints it rather than pretending the alert went out.

  ## Hoogstens drie per onderwerp per uur

  De meeste meldingen komen uit de reconciler, en die tikt elke dertig seconden.
  Een toestand die blijft bestaan -- een uitrol die vastloopt, een schijf die vol
  is -- levert dan twee mails per minuut op. Dat is precies wat er is gebeurd:
  een vastgelopen agent-uitrol heeft in één ochtend het dagquotum van de
  mailserver opgemaakt, en daarna kwam er GEEN ENKELE melding meer door. Ook niet
  de melding over een betaling zonder tegoed, die er wel toe doet.

  Vandaar een rem, en hier en niet bij de aanroepers: de volgende melding die
  iemand toevoegt heeft hem dan vanzelf. Drie per uur per onderwerp, want dat is
  ruim genoeg voor een gebeurtenis die zich echt herhaalt en te weinig voor een
  toestand die elke tik terugkomt. Wat wordt afgeknepen gaat nog wel naar de log,
  zodat er een spoor is.
  """
  # Drie is geen toverwoord: het is "meer dan één, en zichtbaar minder dan wat
  # een toestand per uur zou opleveren" (dat zijn er 120).
  @alerts_per_uur 3
  @alert_venster_ms 60 * 60 * 1000

  def deliver_operational_alert(subject, body) when is_binary(subject) and is_binary(body) do
    case Application.get_env(:control_plane, :ops_email) do
      to when is_binary(to) and to != "" ->
        if mag_melden?(subject) do
          deliver(%{to: to, subject: "[Bunk] " <> subject, text: body, html: nil})
        else
          Logger.warning("melding afgeknepen (al #{@alerts_per_uur}x dit uur): #{subject}")
          {:error, :throttled}
        end

      _ ->
        Logger.error("operational alert not sent (no OPS_EMAIL configured): #{subject}")
        {:error, :no_ops_email}
    end
  end

  defp mag_melden?(subject) do
    RateLimiter.hit("alert:" <> subject, @alerts_per_uur, @alert_venster_ms) == :ok
  end

  defp deliver(%{to: to_email, subject: subject, text: text, html: html}) do
    email =
      new()
      |> to(to_email)
      |> from({from_name(), from_email()})
      |> subject(subject)
      |> text_body(text)

    # An operational alert has no HTML part; Swoosh would otherwise send an empty
    # one, which some clients render as a blank message.
    email = if html, do: html_body(email, html), else: email

    case verstuur_begrensd(email) do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.error("mail delivery failed to #{redact(to_email)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Hoe lang één mail mag duren. gen_smtp wacht op een antwoord van de server
  # tot twintig minuten, en dat is niet in te stellen. Een relay die de
  # verbinding aanneemt en dan zwijgt, hield zo de reconciler twintig minuten
  # vast -- geen nodes offline zetten, geen verlengingen, geen levensteken naar
  # buiten -- of een klant twintig minuten op een registratie. Dertig seconden
  # is ruim voor een gezonde server.
  @mail_timeout_ms 30_000

  defp mail_timeout_ms,
    do: Application.get_env(:control_plane, :mail_timeout_ms, @mail_timeout_ms)

  defp verstuur_begrensd(email) do
    taak =
      Task.async(fn ->
        # Ook throw en exit: de taak hangt aan de aanroeper (Task.async
        # linkt), en een exit die hier ontsnapt neemt die mee -- de
        # reconciler, of het verzoek van een klant die zich registreert.
        try do
          Mailer.deliver(email)
        rescue
          exception -> {:error, {:exception, Exception.message(exception)}}
        catch
          soort, reden -> {:error, {soort, reden}}
        end
      end)

    case Task.yield(taak, mail_timeout_ms()) || Task.shutdown(taak, :brutal_kill) do
      {:ok, uitkomst} -> uitkomst
      nil -> {:error, :timeout}
      {:exit, reden} -> {:error, {:exit, reden}}
    end
  end

  # Never let the user's own address land verbatim in Sentry/log aggregation.
  defp redact(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> String.slice(local, 0, 2) <> "***@" <> domain
      _ -> "***"
    end
  end

  defp from_email, do: Application.get_env(:control_plane, :mail)[:from_email]
  defp from_name, do: Application.get_env(:control_plane, :mail)[:from_name]

  # The customer-facing app origin (Next.js), not the control-plane API host.
  # PUBLIC_URL already serves this role elsewhere (e.g. mollie_controller's
  # redirect_url) because the edge proxies both the API and the app off one host.
  defp public_url,
    do: Application.get_env(:control_plane, :public_url) || "https://app.bunkhosting.nl"
end
