# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :control_plane,
  ecto_repos: [ControlPlane.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Operator/admin API configuration.
#
# `public_url` is the externally reachable control-plane URL embedded in
# node-enrollment install commands. `default_template_id` is the provider VM
# template used when provisioning a VPS without an explicit template.
config :control_plane,
  public_url: System.get_env("PUBLIC_URL", "https://control.bunkhosting.nl"),
  default_template_id: 9000

# Configures the endpoint
config :control_plane, ControlPlaneWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ControlPlaneWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ControlPlane.PubSub,
  live_view: [signing_salt: "ZPz1fXkR"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  # Every key a Logger call passes as metadata has to be named here or the
  # console backend silently drops it — the structured fields would simply not
  # appear, which is worse than not having logged them, because the code says
  # they are there. `crash_reason` is what a rescued exception attaches its
  # stacktrace to; the rest are counters the reconciler's sweeps report.
  metadata: [
    :request_id,
    :crash_reason,
    :marked_offline,
    :reclaimed,
    :metered,
    :retried,
    :started,
    :errors,
    :count,
    # De beheer-audit: wie deed wat, waar, met welke uitkomst.
    :admin,
    :methode,
    :pad,
    :uitkomst,
    # Hoe vol de schijf zat toen erover geklaagd werd.
    :schijf_pct
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.

# VPS data-network range from which the IpPool hands out addresses to customer
# VPSes (Proxmox vmbr2 / 10.10.0.0/19). Override per-env in runtime.exs.
config :control_plane, :vps_network,
  prefix: 19,
  gateway: "10.10.0.1",
  range_start: "10.10.0.20",
  range_end: "10.10.4.254"

# Bank/iDEAL payment details shown to customers funding their wallet. Placeholders
# here; set the real values via runtime config before going live.
config :control_plane, :payment,
  iban: "NL00 BUNK 0000 0000 00",
  beneficiary: "Bunk Hosting",
  bic: "BUNKNL2A"

# Transactional email (confirmation, password reset, low-balance warnings). The
# adapter is per-env (dev.exs/test.exs/runtime.exs); this just sets the sender
# identity, with dev-safe placeholders overridden by runtime.exs in prod.
config :control_plane, :mail,
  from_email: System.get_env("MAIL_FROM_ADDRESS", "noreply@bunkhosting.nl"),
  from_name: System.get_env("MAIL_FROM_NAME", "Bunk Hosting")

# We use Swoosh's SMTP adapter (gen_smtp), not its HTTP-API adapters, so the
# HTTP client pool Swoosh would otherwise start is pure overhead — disable it.
config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
