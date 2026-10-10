defmodule ControlPlaneWeb.Router do
  use ControlPlaneWeb, :router

  # This app was generated with --no-html, so `use Phoenix.Router` does not bring
  # in the `live/3` macro; import it explicitly for the admin dashboard.
  import Phoenix.LiveView.Router
  import ControlPlaneWeb.UserAuth

  # Browser pipeline for the (single) LiveView admin dashboard.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ControlPlaneWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  # Browser routes that require an authenticated portal user.
  pipeline :require_authenticated do
    plug :require_authenticated_user
  end

  # The mirror image: someone already signed in has no business on the login or
  # registration form, and showing it to them invites a second session for the
  # same person. Not applied to /logout, which is for exactly those users.
  pipeline :redirect_if_authenticated do
    plug :redirect_if_user_is_authenticated
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Throttle the public browser auth pages (login/register/MFA) per-client to
  # blunt password + 6-digit-TOTP brute force. Keyed on CF-Connecting-IP.
  pipeline :auth_throttle do
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "browser_auth", max: 20, window_ms: 60_000
  end

  # Admin LiveView dashboard.
  # Admin fleet dashboard — shows EVERY node + EVERY customer's VPS, so
  # it must never be reachable unauthenticated or by a regular customer. Gated to
  # staff (:admin), mirroring RequireAdmin.
  scope "/", ControlPlaneWeb do
    pipe_through [:browser, :require_authenticated]

    live_session :admin_dashboard,
      on_mount: [{ControlPlaneWeb.UserAuth, :ensure_staff}] do
      live "/", DashboardLive, :index
    end
  end

  # Customer portal: public auth pages.
  scope "/", ControlPlaneWeb do
    pipe_through [:browser, :auth_throttle, :redirect_if_authenticated]

    get "/login", UserSessionController, :new
    post "/login", UserSessionController, :create
    # Mid-MFA there is no session token yet, so the redirect above never fires
    # here — the second factor is still ahead of the user.
    get "/login/mfa", UserSessionController, :mfa_new
    post "/login/mfa", UserSessionController, :mfa_create
    get "/register", UserRegistrationController, :new
    post "/register", UserRegistrationController, :create
  end

  scope "/", ControlPlaneWeb do
    pipe_through :browser

    delete "/logout", UserSessionController, :delete
  end

  # The customer portal is served entirely by the Next.js frontend against the
  # JSON API (`/api/v1/*`) and the console WebSocket (`/ws/console/:id`). The old
  # server-rendered LiveView customer stack (:dashboard / :portal) was removed:
  # it was unreachable behind the edge and its create paths didn't charge the
  # wallet, so keeping it was pure attack surface.

  # Worker-node API: everything in `:api` plus agent-token bearer authentication.
  pipeline :node_api do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.NodeAuth
  end

  # The console relay is a WebSocket upgrade, not JSON, so it cannot go through
  # :accepts — but it is still a node calling, so it still authenticates as one.
  pipeline :node_ws do
    plug ControlPlaneWeb.Plugs.NodeAuth
  end

  # Admin API: JSON plus shared-secret admin-token bearer authentication.
  pipeline :admin_api do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.AdminAuth
    plug ControlPlaneWeb.Plugs.AdminAuditLog
  end

  # End-user API: JSON plus per-user session-token bearer authentication.
  pipeline :user_api do
    plug :accepts, ["json"]
    # Vóór de authenticatie: een wijzigend verzoek dat op de cookie leunt moet
    # van ons eigen dashboard komen. Zie de plug.
    plug ControlPlaneWeb.Plugs.SameOrigin
    plug ControlPlaneWeb.Plugs.ApiAuth

    # Ruim, want dit is het hele paneel: de lijst, de details, het bijwerken van
    # statussen. Vijf verzoeken per seconde haalt een mens niet met klikken, maar
    # een script dat `backup_now` in een lus aanroept wel -- en dat kost per
    # poging een transactie, ook als de controle hem daarna afwijst. Op de
    # gebruiker en niet op het IP: zie de plug.
    plug ControlPlaneWeb.Plugs.RateLimit,
      bucket: "user_api",
      max: 300,
      window_ms: 60_000,
      by: :user
  end

  # Admin panel API: authenticated on the caller's OWN session token and gated to
  # the :admin role (distinct from /admin/v1/* which uses a shared secret).
  pipeline :admin_session_api do
    plug :accepts, ["json"]
    # Vóór de authenticatie: een wijzigend verzoek dat op de cookie leunt moet
    # van ons eigen dashboard komen. Zie de plug.
    plug ControlPlaneWeb.Plugs.SameOrigin
    plug ControlPlaneWeb.Plugs.ApiAuth
    plug ControlPlaneWeb.Plugs.RequireAdmin
    plug ControlPlaneWeb.Plugs.RequireAdminMfa
    plug ControlPlaneWeb.Plugs.AdminAuditLog
  end

  scope "/api", ControlPlaneWeb do
    pipe_through :api
  end

  # Where browsers post CSP violations. Unauthenticated by necessity — a browser
  # sends these with no credentials — so it is rate-limited instead, on its own
  # bucket: a flood of reports must not use up the budget that protects login.
  scope "/api/v1", ControlPlaneWeb do
    pipe_through :csp_report

    post "/security/csp-report", SecurityController, :csp_report
  end

  # Public worker installer script (curl | bash).
  scope "/", ControlPlaneWeb do
    pipe_through :api
    get "/install.sh", WorkerInstallController, :script
    get "/agent-update.sh", WorkerInstallController, :update_bootstrap
    # Waar een beveiligingsonderzoeker een vondst kwijt kan (RFC 9116). Open,
    # want dat is het hele punt: het is de enige pagina die iemand zoekt vóór
    # hij besluit waar hij anders naartoe gaat met wat hij gevonden heeft.
    get "/.well-known/security.txt", SecurityController, :security_txt
    # Voor een watchdog buiten deze machine. Open, want een watchdog heeft geen
    # inloggegevens; hij geeft alleen 200 of 503 en verder niets.
    get "/healthz", SecurityController, :healthz
  end

  # Open, unauthenticated auth endpoints are rate-limited per client IP to blunt
  # credential-stuffing and registration spam.
  pipeline :auth_public do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "auth", max: 30, window_ms: 60_000
  end

  # CSP violation reports arrive from browsers with no credentials, so the only
  # control available is volume. Its own bucket: a page generating violations in
  # a loop must not exhaust the budget that protects login.
  pipeline :csp_report do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "csp", max: 60, window_ms: 60_000
  end

  # Public node enrollment is unauthenticated (the single-use enroll token is the
  # credential); throttle per client IP so token guessing / enroll spam can't run
  # unbounded against the DB.
  pipeline :enroll_public do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "enroll", max: 30, window_ms: 60_000
  end

  # Authenticated but throttled: each wallet top-up fans out an authenticated
  # create_payment call to Mollie, so cap per client IP on top of the per-user
  # pending-topup cap in the controller.
  pipeline :user_api_throttled do
    plug :accepts, ["json"]
    # Vóór de authenticatie: een wijzigend verzoek dat op de cookie leunt moet
    # van ons eigen dashboard komen. Zie de plug.
    plug ControlPlaneWeb.Plugs.SameOrigin
    plug ControlPlaneWeb.Plugs.ApiAuth
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "topup", max: 15, window_ms: 60_000
  end

  # Password-reset requests fan out a real email to a caller-supplied address —
  # tighter than the general :auth_public bucket, since flooding this is a way to
  # mail-bomb a stranger's inbox, not just brute-force a login.
  pipeline :password_reset_throttle do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "password_reset", max: 5, window_ms: 60_000
  end

  # Public webhook: still no auth (Mollie can't authenticate), but rate-limited so
  # it can't be flooded to amplify outbound get_payment fetches / hammer Mollie.
  # 120/min/ip is far above Mollie's real callback rate for one merchant.
  pipeline :webhook do
    plug :accepts, ["json"]
    plug ControlPlaneWeb.Plugs.RateLimit, bucket: "webhook", max: 120, window_ms: 60_000
  end

  # Public Mollie webhook. Safety comes from fetch-to-verify + idempotent,
  # amount-checked crediting; the rate limit only caps abuse volume.
  scope "/api/v1", ControlPlaneWeb do
    pipe_through :webhook

    post "/billing/mollie/webhook", MollieController, :webhook
  end

  scope "/api/v1", ControlPlaneWeb do
    pipe_through :auth_public

    post "/auth/register", AuthController, :register
    post "/auth/login", AuthController, :login

    # Email-confirmation link exchange (token IS the credential; no session needed).
    post "/auth/confirm", AuthController, :confirm

    # Password-reset link exchange (token IS the credential).
    post "/auth/password-reset/confirm", AuthController, :reset_password

    # Public, read-only VPS package catalog.
    get "/packages", PackageController, :index
  end

  # "Forgot password" request gets its own tighter bucket — see
  # :password_reset_throttle above.
  scope "/api/v1", ControlPlaneWeb do
    pipe_through :password_reset_throttle

    post "/auth/password-reset", AuthController, :request_password_reset
  end

  scope "/api/v1", ControlPlaneWeb do
    pipe_through :user_api

    get "/auth/me", AuthController, :me
    delete "/auth/logout", AuthController, :logout
    delete "/auth/logout/all", AuthController, :logout_all
    patch "/auth/password", AuthController, :change_password

    # Two-factor (TOTP) — bunk-fleet's own Accounts feature, exposed for the UI.
    get "/auth/totp/setup", AuthController, :totp_setup
    post "/auth/totp/setup", AuthController, :totp_confirm
    delete "/auth/totp/disable", AuthController, :totp_disable

    # Passkeys (WebAuthn). Registreren is twee stappen: een challenge ophalen en
    # het antwoord van de authenticator terugsturen. Inloggen met een passkey
    # loopt via POST /auth/login zelf, net als TOTP.
    get "/auth/passkeys", AuthController, :passkeys_list
    post "/auth/passkeys/challenge", AuthController, :passkey_register_challenge
    post "/auth/passkeys", AuthController, :passkey_register
    delete "/auth/passkeys/:id", AuthController, :passkey_delete

    # Re-send the confirmation email (authenticated, so it can't spam an arbitrary
    # address — see AuthController.resend_confirmation/2).
    post "/auth/confirm/resend", AuthController, :resend_confirmation

    # Where a VPS can be placed. Listed rather than hardcoded in the UI, because
    # the answer changes when a node joins, fills up or goes offline.
    get "/regions", RegionController, :index

    # De nodes die deze gebruiker beheert, en hun instellingen. Bewust hier en
    # niet onder /beheer: de eigenaar van een node is niet per se een beheerder,
    # en die scope zou hem buiten de deur houden.
    get "/nodes", NodeController, :index
    patch "/nodes/:id/settings", NodeController, :update_settings
    post "/nodes/:id/owner", NodeController, :assign_owner
    post "/nodes/:id/region", NodeController, :move_region

    # Self-service VPS lifecycle, scoped to the authenticated owner.
    resources "/vpses", VpsController, only: [:index, :show, :create, :update, :delete]
    post "/vpses/:id/start", VpsController, :start
    post "/vpses/:id/stop", VpsController, :stop
    post "/vpses/:id/reboot", VpsController, :reboot
    post "/vpses/:id/console-ticket", ConsoleController, :create_ticket
    get "/vpses/:id/backups", VpsController, :backups
    post "/vpses/:id/backups", VpsController, :backup_now
    post "/vpses/:id/backups/:backup_id/restore", VpsController, :restore

    # The caller's own prepaid wallet: balance, ledger movements, top-ups.
    get "/billing/wallet", BillingController, :wallet

    # The caller's own metered usage and cost.
    get "/billing/usage", BillingController, :usage
  end

  # Mollie wallet top-up: create a payment, return its checkout URL. Split into a
  # throttled scope so the outbound Mollie fan-out is rate-limited per client IP.
  scope "/api/v1", ControlPlaneWeb do
    pipe_through :user_api_throttled

    post "/billing/topup", MollieController, :topup
  end

  # Session-authenticated admin panel (role :admin). Powers the dashboard's admin
  # section: platform stats, user management, a fleet-wide VPS view + lifecycle
  # actions, and a node overview.
  #
  # NOTE: mounted at /beheer (not /admin) on purpose — Cloudflare's managed WAF
  # blocks "/admin" URL paths with an HTML challenge page before they ever reach
  # the origin, which would 403 every call from the browser.
  scope "/api/v1/beheer", ControlPlaneWeb.Admin do
    pipe_through :admin_session_api

    get "/stats", PanelController, :stats
    get "/metrics", PanelController, :metrics
    get "/omzet", PanelController, :revenue
    get "/users", PanelController, :users
    get "/users/:id", PanelController, :user_detail
    get "/subscriptions", PanelController, :subscriptions
    get "/commands", PanelController, :commands
    patch "/users/:id", PanelController, :update_user
    post "/users/:id/credit", PanelController, :credit_user
    delete "/users/:id", PanelController, :delete_user
    get "/vpses", PanelController, :vpses
    post "/vpses/:id/start", PanelController, :vps_start
    post "/vpses/:id/stop", PanelController, :vps_stop
    delete "/vpses/:id", PanelController, :vps_delete
    get "/regions", PanelController, :regions
    post "/regions", PanelController, :create_region
    patch "/regions/:id", PanelController, :update_region
    delete "/regions/:id", PanelController, :delete_region
    get "/nodes", PanelController, :nodes
    # Een node toevoegen hoort hier en niet alleen onder /admin/v1: dat pad wordt
    # door Cloudflare's WAF geblokkeerd voor het de origin bereikt, waardoor het
    # vanuit de browser onbereikbaar is. Zie de opmerking boven deze scope.
    post "/enroll-tokens", PanelController, :create_enroll_token
    post "/nodes/:id/drain", PanelController, :drain_node
    post "/nodes/:id/resume", PanelController, :resume_node
    delete "/nodes/:id", PanelController, :delete_node
  end

  # Browser console WebSocket. No router pipeline (a WS upgrade isn't JSON); the
  # single-use ticket in the query string is the credential, redeemed here.
  scope "/ws", ControlPlaneWeb do
    get "/console/:id", ConsoleController, :ws
  end

  # bunk-agent onboarding / heartbeat / command API.
  scope "/v1", ControlPlaneWeb do
    pipe_through :enroll_public

    post "/enroll", EnrollController, :enroll
  end

  scope "/v1", ControlPlaneWeb do
    pipe_through :node_api

    post "/heartbeat", HeartbeatController, :create
    get "/commands", CommandController, :index
    post "/commands/:id/result", CommandController, :result

    # Desired firewall state for this node's VPSes. Polled, not pushed, so a node
    # that was away converges instead of missing the events it slept through.
    get "/port-forwards", PortForwardController, :index
  end

  # The node dials this back after seeing a console_connect request on its poll,
  # and pipes the VPS's SSH stream through it. Both credentials are checked: the
  # agent token proves which node is calling, the relay token which console.
  scope "/v1", ControlPlaneWeb do
    pipe_through :node_ws

    get "/console-relay", ConsoleController, :relay_ws
  end

  # Admin API.
  scope "/admin/v1", ControlPlaneWeb.Admin do
    pipe_through :admin_api

    resources "/regions", RegionController, only: [:index, :create]
    post "/enroll-tokens", EnrollTokenController, :create
    get "/nodes", NodeController, :index
    # Take a node out of service without taking anything from the VPSes on it.
    post "/nodes/:id/drain", NodeController, :drain
    post "/nodes/:id/resume", NodeController, :resume
    get "/vpses", VpsController, :index
    post "/vpses", VpsController, :create
    delete "/vpses/:id", VpsController, :delete
    get "/billing/usage", BillingController, :usage
    get "/credits", CreditController, :show
    post "/credits", CreditController, :create
    get "/topups", TopupController, :index
    post "/topups/:id/confirm", TopupController, :confirm
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:control_plane, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: ControlPlaneWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
