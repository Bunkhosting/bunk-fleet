import Config

# De build waar deze release uit komt. De agent wordt uit dezelfde boom gebouwd
# en meldt hetzelfde stempel in zijn heartbeat, dus hieraan leest de uitrol af
# welke nodes nog achterlopen. Ontbreekt hij, dan is er niets om tegen af te
# lezen en doet de uitrol niets; de nachtelijke timer op elke node is dan het
# vangnet.
config :control_plane, build_version: System.get_env("BUNK_BUILD_VERSION")

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/control_plane start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :control_plane, ControlPlaneWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :control_plane, ControlPlane.Repo,
    # ssl: true,
    url: database_url,
    # Tien is een gekozen getal en geen toeval: op twee cores is de CPU eerder op
    # dan de pool, en meer verbindingen maken het dan alleen maar drukker bij
    # Postgres. Komt er hardware bij, dan is dit het getal dat meeschuift --
    # daarom staat het in de omgeving en niet in de code.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :control_plane, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :control_plane, ControlPlaneWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://#{host}"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Operator/admin shared-secret token and the externally-reachable URL embedded in
  # node-enrollment install commands. Read HERE (runtime), not config.exs, so a
  # release picks them up from the environment at boot instead of freezing a
  # build-time value.
  console_private_key =
    case System.get_env("CONSOLE_SSH_PRIVATE_KEY") do
      b64 when is_binary(b64) and b64 != "" -> Base.decode64!(b64)
      _ -> nil
    end

  console_public_key =
    case System.get_env("CONSOLE_SSH_PUBLIC_KEY") do
      b64 when is_binary(b64) and b64 != "" -> Base.decode64!(b64)
      _ -> nil
    end

  config :control_plane,
    admin_token: System.get_env("ADMIN_TOKEN"),
    public_url: System.get_env("PUBLIC_URL") || "https://#{host}",
    console: [
      ssh_private_key: console_private_key,
      ssh_public_key: console_public_key,
      ssh_user: System.get_env("CONSOLE_SSH_USER") || "ubuntu",
      # Waarmee de eigen consolesleutel van elke VPS versleuteld in de database
      # staat: 32 bytes, base64. Staat hij er niet, dan krijgen nieuwe VPS'en
      # geen eigen sleutel en blijft de gedeelde in gebruik -- zie
      # `ControlPlane.Console.Keys`. Bewust in de omgeving en niet in de
      # database: een databasedump zonder deze sleutel levert niets op.
      key_encryption_key: System.get_env("CONSOLE_KEY_ENC")
    ]

  config :control_plane, :mollie, api_key: System.get_env("MOLLIE_API_KEY")

  # Cloudflare Turnstile server-side secret. When set, registration verifies the
  # CAPTCHA token server-side (blocks API-direct signup-bonus farming); when unset,
  # verification is skipped.
  config :control_plane, :turnstile, secret_key: System.get_env("TURNSTILE_SECRET_KEY")

  # Billing rates (money per resource-hour) as decimal strings — `ControlPlane.Billing`
  # coerces them to Decimal so money math stays exact. Non-zero defaults so a fresh
  # prod deploy meters something rather than billing everyone €0.
  config :control_plane,
    billing_rates: %{
      vcpu: System.get_env("RATE_VCPU") || "0.010",
      ram_gb: System.get_env("RATE_RAM_GB") || "0.004",
      disk_gb: System.get_env("RATE_DISK_GB") || "0.0002"
    }

  # Per-owner active-VPS quota for self-service create (default 10 in code).
  if max = System.get_env("MAX_VPSES_PER_OWNER") do
    config :control_plane, max_vpses_per_owner: String.to_integer(max)
  end

  # Transactional email (confirmation, password reset, low-balance warning) via
  # SMTP. When SMTP_HOST is unset we deliberately do NOT crash the boot — mirrors
  # how MOLLIE_API_KEY/TURNSTILE_SECRET_KEY degrade — but mail genuinely will not
  # be delivered (Swoosh.Adapters.Local just stores it in the release's memory),
  # so this is loud in the boot log rather than a silent no-op.
  if System.get_env("SMTP_HOST") do
    # The TLS-mode/CA-bundle derivation is deliberately NOT inline here: it is
    # subtle (port decides :sockopts vs :tls_options, and gen_smtp ignores the
    # wrong one without a word) and therefore lives in a tested module. Calling
    # it at this point is safe — modules are loaded before runtime.exs is
    # evaluated — and it needs no running application.
    config :control_plane,
           ControlPlane.Mailer,
           ControlPlane.Mailer.Config.smtp_options_from_system_env()

    config :control_plane, :mail,
      from_email: System.get_env("MAIL_FROM_ADDRESS") || "noreply@#{host}",
      from_name: System.get_env("MAIL_FROM_NAME") || "Bunk Hosting"

    # Where operational alerts go — a backup that failed, not a customer email.
    # No default: guessing an address means the alert goes somewhere nobody
    # reads, which is worse than the caller being told it was not sent.
    config :control_plane, :ops_email, System.get_env("OPS_EMAIL")
  else
    # NOT Logger.warning/1 here: config/runtime.exs runs before the :logger
    # application's console backend is attached, so a Logger call at this point
    # is silently dropped — verified empirically, it never reaches `docker logs`.
    # IO.puts to stderr is the only thing guaranteed to show up this early.
    IO.puts(
      :stderr,
      "[warning] SMTP_HOST is not set — confirmation/reset/low-balance emails will NOT be delivered."
    )

    config :control_plane, ControlPlane.Mailer, adapter: Swoosh.Adapters.Local
  end

  # Het adres waar het control plane elke minuut een levensteken heen stuurt.
  #
  # Bewust BUITEN het SMTP-blok hierboven: deze switch bestaat juist voor de
  # gevallen waarin mailen niet meer lukt of het hele proces weg is. Leeg = uit,
  # en dat meldt de reconciler één keer bij het opstarten zodat "staat uit" en
  # "werkt" niet op elkaar lijken.
  config :control_plane, :deadman_url, System.get_env("DEADMAN_URL")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :control_plane, ControlPlaneWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :control_plane, ControlPlaneWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
