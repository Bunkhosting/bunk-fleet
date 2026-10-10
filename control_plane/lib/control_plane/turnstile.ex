defmodule ControlPlane.Turnstile do
  @moduledoc """
  Server-side verification of Cloudflare Turnstile (CAPTCHA) tokens.

  The frontend renders the widget and sends its token; without a *server-side*
  check a bot can simply call the JSON API directly and skip the widget entirely
  (which is what enables signup-bonus farming / credential stuffing). `verify/2`
  closes that by POSTing the token to Cloudflare's siteverify.

  Config-gated: when `:control_plane, :turnstile, :secret_key` is set (env
  `TURNSTILE_SECRET_KEY`), verification is enforced — a missing/invalid/unverifiable
  token is rejected. When no secret is configured, verification is skipped so the
  platform still runs; **set `TURNSTILE_SECRET_KEY` in prod to activate it.**
  """
  require Logger

  alias ControlPlane.Notifier
  alias ControlPlane.RateLimiter

  @endpoint "https://challenges.cloudflare.com/turnstile/v0/siteverify"

  @doc "True when a secret key is configured (verification enforced)."
  def enabled?, do: is_binary(secret()) and secret() != ""

  @doc """
  Returns `:ok` when the token is valid (or verification is disabled), else
  `{:error, :captcha_required | :captcha_failed | :captcha_unavailable}`.
  Fails closed when enabled: a verification outage rejects rather than admits.
  """
  def verify(token, remote_ip \\ nil) do
    cond do
      not enabled?() ->
        :ok

      not (is_binary(token) and token != "") ->
        {:error, :captcha_required}

      true ->
        do_verify(token, remote_ip)
    end
  end

  defp do_verify(token, remote_ip) do
    form = %{secret: secret(), response: token} |> put_ip(remote_ip)

    # Ook een grens op het verbinden: receive_timeout begint pas te tellen
    # als er een verbinding is, en zonder deze wachtte een registratie tot
    # de standaard van de client op een Cloudflare die niet opnam.
    options =
      [
        url: @endpoint,
        form: form,
        receive_timeout: 5_000,
        connect_options: [timeout: 3_000],
        retry: false
      ] ++
        (config(:req_options) || [])

    case Req.post(options) do
      {:ok, %{status: 200, body: %{"success" => true}}} ->
        :ok

      {:ok, %{status: 200, body: body}} ->
        Logger.warning(
          "turnstile verify rejected: #{inspect(is_map(body) && body["error-codes"])}"
        )

        {:error, :captcha_failed}

      # Een 5xx of 429 van Cloudflare is een storing bij hen, geen afgewezen
      # captcha. Als afwijzing telde hij mee voor de melding "de site key hoort
      # niet bij het geheim" -- iemand ging een configuratie zitten controleren
      # die niets mankeerde.
      {:ok, %{status: status}} ->
        Logger.warning("turnstile verify unavailable: HTTP #{status}")
        {:error, :captcha_unavailable}

      {:error, reason} ->
        Logger.warning("turnstile verify unavailable: #{inspect(reason)}")
        {:error, :captcha_unavailable}
    end
  end

  @doc """
  Records that a registration was turned away by the CAPTCHA, and tells a person
  the first time it happens in any hour.

  Two very different things produce this, and from the server they look
  identical: a bot being stopped, which is the feature working, and a site key
  that does not belong to the configured secret, which silently blocks every
  real customer instead. Nobody finds out about the second one from a log line —
  they find out from a customer who gave up. So the first rejection each hour
  goes to the ops address with both readings and how to tell them apart.

  Rate-limited to one message an hour: a bot farm must not turn this into a mail
  flood, and the second alert of an hour says nothing the first did not.
  """
  def note_rejection(reason) do
    Logger.warning("registration refused by turnstile: #{reason}")

    if RateLimiter.hit("turnstile_rejection_alert", 1, :timer.hours(1)) == :ok do
      Notifier.deliver_operational_alert(
        "Een registratie is door de CAPTCHA tegengehouden",
        """
        Reden: #{reason}

        Dit betekent een van twee dingen.

        1. Turnstile doet zijn werk en heeft een bot tegengehouden. Dan hoef je
           niets te doen; dit bericht komt hoogstens eens per uur.

        2. De site key in de frontend hoort niet bij TURNSTILE_SECRET_KEY in
           .env.prod, of niet bij het domein app.bunkhosting.nl. Dan wordt NIEMAND
           meer toegelaten tot registratie.

        Zo zie je het verschil: open https://app.bunkhosting.nl/register in een
        browser. Verschijnt het CAPTCHA-vakje en kun je een account aanmaken, dan
        is het geval 1. Blijft het vakje leeg of hangt het, dan is het geval 2 en
        staan de sleutels verkeerd.

        Terugdraaien is één regel: haal TURNSTILE_SECRET_KEY uit
        /opt/bunk-fleet/.env.prod en start de control plane opnieuw. Registratie
        werkt dan meteen weer, zonder CAPTCHA.
        """
      )
    end

    :ok
  end

  defp put_ip(form, ip) when is_binary(ip) and ip != "", do: Map.put(form, :remoteip, ip)
  defp put_ip(form, _), do: form

  defp secret, do: config(:secret_key)

  # `:req_options` is how the test suite points this at a stub instead of
  # Cloudflare. Nothing sets it in production.
  defp config(key), do: Application.get_env(:control_plane, :turnstile, [])[key]
end
