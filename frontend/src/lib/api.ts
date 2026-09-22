/**
 * API adapter — bridges the (unchanged) vps-frontend UI to the bunk-fleet
 * (Elixir) control-plane API.
 *
 * bunk-fleet uses bearer session tokens (Authorization: Bearer <token>) instead
 * of the old Django cookie+CSRF+JWT-refresh model, and returns its own JSON
 * shapes. This module is the single boundary that:
 *   - stores the bearer token client-side and attaches it to every request,
 *   - transforms bunk-fleet responses into the frontend's existing TS types,
 * so the React components stay byte-for-byte identical.
 */
import axios from "axios";
import type {
  User,
  Vps,
  VpsCredentials,
  VpsPackage,
  VpsStatus,
  OsChoice,
  BillingOverview,
} from "./types";

const API_URL = process.env.NEXT_PUBLIC_API_URL || "";

// Auth is carried by an HttpOnly `bunk_session` cookie set by the control plane on
// login/register and cleared on logout. The token is deliberately NOT kept in
// localStorage or any JS-readable place, so an XSS foothold can't exfiltrate a
// live session. Requests must be same-origin (the default: an empty API_URL routes
// through the Next `/api/v1` rewrite) for the browser to send the cookie;
// `withCredentials` below also covers a same-site cross-origin API host. The
// middleware gates /dashboard by reading the same cookie server-side.
function resetClientState(): void {
  // Drop cached catalog so a different user/session in the same tab refetches.
  packageCache = [];
  packagesPromise = null;
}

// Known bunk-fleet error codes -> friendly Dutch messages. Unknown codes fall
// back to the caller-supplied contextual message (never a raw code in the UI).
// Machine codes the control plane sends in `{ error: "..." }`, translated for the
// person reading them. Not every code needs an entry: anything missing falls back
// to the caller's own contextual message, which is usually more specific than a
// generic sentence would be. What must never happen is a raw code reaching a
// customer, and parseApiError below is what guarantees that.
const ERROR_MESSAGES: Record<string, string> = {
  // Authentication
  invalid_credentials: "Ongeldig e-mailadres of wachtwoord.",
  invalid_code: "De ingevoerde code klopt niet.",
  invalid_token: "Deze link is ongeldig of verlopen.",
  email_taken: "Dit e-mailadres is al in gebruik.",
  already_confirmed: "Je account is al bevestigd.",
  unauthorized: "Je bent niet (meer) ingelogd.",
  forbidden: "Je hebt geen toegang tot deze actie.",
  // Let op: `mfa_required` betekent in het inlogantwoord iets anders (er moet
  // nog een TOTP-code volgen). Deze code heeft daarom een eigen naam.
  admin_mfa_required:
    "Het beheerpaneel vraagt een tweede factor. Zet een authenticator-app of een passkey aan onder Beveiliging.",
  not_found: "Niet gevonden.",
  rate_limited: "Te veel pogingen. Probeer het over een minuutje opnieuw.",
  captcha_failed: "De verificatie is niet gelukt. Probeer het opnieuw.",

  // Een VPS bestellen
  insufficient_credits: "Je tegoed is niet toereikend voor deze VPS.",
  quota_exceeded: "Je hebt het maximum aantal VPS'en bereikt.",
  no_capacity: "Er is op dit moment geen capaciteit vrij in deze regio.",
  port_pool_exhausted:
    "Deze machine heeft geen vrije poorten meer voor nieuwe VPS'en. Probeer een andere locatie.",

  // Een locatie verwijderen. Drie redenen waarom het niet kan, en ze vragen om
  // iets anders van degene die het probeert.
  has_nodes: "Er staan nog nodes in deze locatie. Verplaats die eerst.",
  has_vpses:
    "In deze locatie heeft een VPS gedraaid. Die geschiedenis blijft bewaard, dus de locatie kan niet weg — sluiten kan wel.",
  has_enroll_tokens:
    "Er staat nog een uitnodiging open voor deze locatie. Trek die eerst in.",
  no_matching_package: "Deze combinatie van cpu, geheugen en schijf is niet te bestellen.",
  invalid_vps: "Deze specificatie kan niet.",
  region_not_found: "Deze regio bestaat niet.",
  region_ambiguous: "Er zijn meerdere locaties — kies waar deze node komt te staan.",
  region_code_taken: "Die code is al van een andere locatie.",
  invalid_region_code: "Een code mag alleen kleine letters, cijfers en koppeltekens bevatten.",
  invalid_region: "Vul een plaatsnaam in van twee tot zestig tekens.",
  unknown_region: "Deze locatie bestaat niet.",
  no_delivery_consent:
    "Bevestig dat je VPS meteen aangemaakt mag worden voordat je bestelt.",
  order_in_progress:
    "Je hebt al een bestelling lopen. Wacht tot die klaar is voor je er nog een plaatst.",

  // Een bestaande VPS bedienen. invalid_status_* zegt precies welke staat in de
  // weg zit, wat bruikbaarder is dan "dat kan nu niet".
  invalid_status_active: "De VPS draait al.",
  invalid_status_stopped: "De VPS is al gestopt.",
  invalid_status_queued: "De VPS wordt nog voorbereid.",
  invalid_status_provisioning: "De VPS wordt nog aangemaakt.",
  invalid_status_restoring: "Er wordt een back-up teruggezet; wacht tot dat klaar is.",
  invalid_status_deleted: "Deze VPS is verwijderd.",
  already_deleting: "Deze VPS wordt al verwijderd.",
  not_provisioned: "Deze VPS is nog niet klaar.",
  vps_not_active: "Dit kan alleen bij een draaiende VPS.",
  console_unavailable: "De console is nu niet beschikbaar voor deze VPS.",
  backup_not_restorable: "Deze back-up kan niet teruggezet worden.",
  backup_already_running: "Er loopt al een back-up van deze VPS.",
  node_unreachable: "De machine waarop deze VPS draait is nu niet bereikbaar.",

  // Betalen
  invalid_amount: "Dit bedrag kan niet.",
  too_many_pending_topups: "Je hebt al te veel openstaande betalingen openstaan.",
  payment_rejected: "De betaling is geweigerd.",
  payment_provider_error: "Betalen lukt nu even niet. Probeer het later opnieuw.",
  payments_unavailable: "Betalen is tijdelijk uitgeschakeld.",

  // Het beheerpaneel. Deze codes zien alleen wij, maar de contextuele zin van
  // het paneel ("verwijderen is niet gelukt") laat in het midden wat er dan wél
  // moet gebeuren -- en dat is hier juist het hele antwoord.
  user_has_vpses: "Deze klant heeft nog VPS'en. Verwijder die eerst.",
  node_has_vpses: "Op deze node draaien nog VPS'en. Verplaats of verwijder die eerst.",
  cannot_delete_self: "Je kunt je eigen account niet verwijderen.",
  cannot_demote_self: "Je kunt je eigen beheerdersrol niet afnemen.",
  invalid_role: "Deze rol bestaat niet.",
  unknown_user: "Deze gebruiker bestaat niet.",
  invalid_owner: "Deze eigenaar bestaat niet.",
  no_node: "Er is geen node waar dit op kan draaien.",

  // Geldt overal: een verzoek dat groter is dan wat we aannemen.
  input_too_large: "Wat je verstuurde is te groot.",
};

/**
 * Turns an unknown thrown value (usually an Axios error) into a human-readable
 * Dutch message. Recognises bunk-fleet's error shapes — { error: "code" },
 * { detail: "..." }, and changeset-style { errors: { field: [msg] } } — and
 * otherwise returns the caller's contextual fallback. Never surfaces raw codes.
 */
export function parseApiError(err: unknown, fallback: string): string {
  if (axios.isAxiosError(err)) {
    const data = err.response?.data as Record<string, unknown> | string | undefined;
    if (data && typeof data === "object") {
      // Only surface a short, plain-text detail — never an HTML error page body.
      if (
        typeof data.detail === "string" &&
        data.detail.length > 0 &&
        data.detail.length < 200 &&
        !data.detail.includes("<")
      ) {
        return data.detail;
      }
      if (typeof data.error === "string") return ERROR_MESSAGES[data.error] ?? fallback;
      const errors = data.errors;
      if (errors && typeof errors === "object") {
        const first = Object.values(errors as Record<string, unknown>)[0];
        if (Array.isArray(first) && typeof first[0] === "string") return first[0];
        if (typeof first === "string") return first;
      }
    }
    if (err.code === "ERR_NETWORK") {
      return "Geen verbinding met de server. Probeer het later opnieuw.";
    }
  }
  return fallback;
}

const api = axios.create({
  baseURL: `${API_URL}/api/v1`,
  headers: { "Content-Type": "application/json" },
  // Send the HttpOnly session cookie with every request (needed for a same-site
  // cross-origin API host; a no-op for the same-origin default).
  withCredentials: true,
});

api.interceptors.response.use(
  (response) => response,
  (error) => {
    const status = error.response?.status;
    const url: string = error.config?.url || "";
    // Fail securely: a 401 outside the auth flow means the session is gone — drop
    // the token and send the user back to login.
    if (status === 401 && typeof window !== "undefined" && !url.includes("/auth/login") && !window.location.pathname.startsWith("/login")) {
      resetClientState();
      // Bewust een harde navigatie en geen router.push: dit is een
      // axios-interceptor buiten de React-boom, waar geen router bestaat. Een
      // volledige herlaadbeurt is hier bovendien het doel — na een verlopen
      // sessie mag er geen component blijven staan met oude gegevens erin.
      // eslint-disable-next-line @next/next/no-location-assign-relative-destination
      window.location.href = "/login";
    }
    return Promise.reject(error);
  }
);

// ── Transforms (bunk-fleet shapes → frontend types) ───────────────────
const STATUS_MAP: Record<string, VpsStatus> = {
  active: "ACTIVE",
  stopped: "STOPPED",
  paused: "STOPPED",
  queued: "PENDING",
  provisioning: "PROVISIONING",
  restoring: "RESTORING",
  failed: "ERROR",
  deleting: "DELETING",
  deleted: "DELETED",
};

// De beheerschermen krijgen de VPS-rijen ongefilterd binnen en tonen dus de
// status van het control plane zelf. Die vertaling hoort op één plek te staan,
// anders staat er in het ene scherm "provisioning" en in het andere "Aanmaken".
export const vpsStatusFromApi = (raw: string): VpsStatus =>
  STATUS_MAP[raw] ?? "PENDING";

let packageCache: VpsPackage[] = [];
let packagesPromise: Promise<VpsPackage[]> | null = null;

// Memoize the in-flight request (not just the result) so concurrent first
// callers — e.g. /dashboard firing authApi.me() + vpsApi.list() together — share
// ONE GET /packages instead of each firing their own. Reset on logout.
async function ensurePackages(): Promise<VpsPackage[]> {
  if (packageCache.length > 0) return packageCache;
  if (!packagesPromise) {
    packagesPromise = api
      .get<{ count: number; results: VpsPackage[] }>("/packages")
      .then((res) => {
        packageCache = res.data.results;
        return packageCache;
      })
      .catch((err) => {
        packagesPromise = null; // allow a retry on the next call
        throw err;
      });
  }
  return packagesPromise;
}

// Wat er van een VPS te zeggen valt als de server geen pakket meestuurt: de
// specs van de machine zelf, en geen prijs.
//
// Er wordt hier met opzet NIET in de catalogus gezocht naar een pakket met
// dezelfde specs. Dat leek een nette terugval en is het niet: dan staat de
// prijsregel op twee plekken, en de tweede plek kent alleen wat vandaag te koop
// is. Zet een pakket uit het aanbod, en elke bestaande klant op dat pakket ziet
// ineens de prijs van een ánder pakket dat toevallig even groot is. Wat iemand
// betaalt is een feit van de server; weet de server het niet, dan weet dit
// scherm het ook niet.
//
// De prijs is daarom leeg en niet "0.00". Een VPS zonder pakket is niet gratis,
// en dat op het scherm zetten is geen nette terugval maar een onwaarheid over
// iemands rekening. Het scherm toont hierop "onbekend".
function pakketUitSpecs(vcpu: number, ramMb: number, diskGb: number): VpsPackage {
  return {
    id: 0,
    name: "Onbekend pakket",
    cpu_cores: vcpu,
    ram_gb: Math.round(ramMb / 1024),
    disk_gb: diskGb,
    bandwidth_mbit: 0,
    price_monthly: "",
    description: "",
  };
}

interface BunkVps {
  id: string;
  name: string;
  status: string;
  ip_address: string | null;
  vcpu: number;
  ram_mb: number;
  disk_gb: number;
  region?: string | null;
  provider_vm_id?: string | null;
  public_host?: string | null;
  ssh_port?: number | null;
  inserted_at: string;
  /**
   * Het pakket zoals de SERVER het kent, via `package_id` op de rij. `null`
   * wanneer het pakket uit de catalogus is gehaald — dat is iets anders dan
   * gratis, en het scherm hoort dan "onbekend" te tonen.
   */
  package?: {
    id: number;
    name: string;
    cpu_cores: number;
    ram_gb: number;
    disk_gb: number;
    bandwidth_mbit: number;
    price_monthly: string;
  } | null;
}

function transformVps(v: BunkVps): Vps {
  return {
    id: v.id,
    label: v.name,
    // `description` hoort bij VpsPackage maar niet bij wat de server hier stuurt:
    // de omschrijving is verkooptekst uit de catalogus en zegt niets over deze
    // machine.
    package: v.package
      ? { ...v.package, description: "" }
      : pakketUitSpecs(v.vcpu, v.ram_mb, v.disk_gb),
    os: "ubuntu-22.04",
    status: vpsStatusFromApi(v.status),
    ip_address: v.ip_address,
    hostname: null,
    public_host: v.public_host ?? null,
    // Null, not 22: a VPS whose node has no public address has no SSH port
    // either, and showing one would be an invitation to a connection that
    // cannot succeed.
    ssh_port: v.ssh_port ?? null,
    ssh_username: "root",
    vcenter_vm_id: v.provider_vm_id ?? null,
    created_at: v.inserted_at,
    updated_at: v.inserted_at,
    owner: "",
    owner_email: null,
  };
}

interface BunkUser {
  id: string;
  email: string;
  name: string | null;
  role: "user" | "admin";
  inserted_at?: string;
  totp_enabled?: boolean;
  passkeys_enabled?: boolean;
  owns_nodes?: boolean;
  confirmed_at?: string | null;
}

function transformUser(u: BunkUser): User {
  return {
    id: u.id,
    email: u.email,
    name: u.name || u.email,
    role: u.role,
    date_joined: u.inserted_at || "",
    is_active: true,
    totp_enabled: Boolean(u.totp_enabled),
    passkeys_enabled: Boolean(u.passkeys_enabled),
    owns_nodes: Boolean(u.owns_nodes),
    confirmed_at: u.confirmed_at ?? null,
  };
}

// ── Auth ──────────────────────────────────────────────────────────────
/** What a login attempt can tell the caller beyond "it worked". */
export type LoginResult = {
  /** Wachtwoord klopt, tweede factor nodig. */
  mfa_required?: boolean;
  /** Blijft bestaan voor de oude client; gelijk aan methods.includes("totp"). */
  totp_required?: boolean;
  methods?: ("totp" | "passkey")[];
  /** Meteen meegegeven zodat de browser er niet nog een rondje voor hoeft. */
  passkey_challenge?: PasskeyChallenge | null;
  verification_required?: boolean;
};

/** Wat de browser terugkrijgt na navigator.credentials.get(), al base64url-gecodeerd. */
export type PasskeyAssertion = {
  challenge_id: string;
  id: string;
  response: { authenticatorData: string; signature: string; clientDataJSON: string };
};

export type PasskeyChallenge = {
  challenge_id: string;
  /** Rechtstreeks door te geven als `publicKey` aan navigator.credentials.*(). */
  public_key: Record<string, unknown>;
};

export type LoginResponse = {
  user?: BunkUser;
  token?: string;
  /** Wachtwoord klopt, tweede factor nodig. */
  mfa_required?: boolean;
  /** Blijft bestaan voor de oude client; gelijk aan methods.includes("totp"). */
  totp_required?: boolean;
  methods?: ("totp" | "passkey")[];
  passkey_challenge?: PasskeyChallenge | null;
  verification_required?: boolean;
  error?: string;
};

export type Passkey = {
  id: string;
  label: string;
  created_at: string;
  last_used_at: string | null;
};

// WebAuthn werkt met ArrayBuffers; de API met base64url zonder padding.
export const b64url = {
  // Geen spread over de Uint8Array: het compile-target van dit project laat
  // dat niet toe, en een lus is hier even duidelijk.
  encode: (buf: ArrayBuffer): string => {
    const bytes = new Uint8Array(buf);
    let bin = "";
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  },
  decode: (s: string): ArrayBuffer => {
    const b = atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "="));
    const out = new Uint8Array(b.length);
    for (let i = 0; i < b.length; i++) out[i] = b.charCodeAt(i);
    return out.buffer;
  },
};

/** Zet de challenge van de server om naar wat de browser-API wil: bytes i.p.v. strings. */
export function toPublicKeyOptions(pk: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = { ...pk, challenge: b64url.decode(pk.challenge as string) };
  if (pk.user) out.user = { ...(pk.user as object), id: b64url.decode((pk.user as { id: string }).id) };
  for (const k of ["excludeCredentials", "allowCredentials"]) {
    const list = pk[k] as { id: string; type: string }[] | undefined;
    if (list) out[k] = list.map((c) => ({ ...c, id: b64url.decode(c.id) }));
  }
  return out;
}

export const authApi = {
  /**
   * Wijzigt het wachtwoord van wie is ingelogd.
   *
   * Het huidige wachtwoord moet erbij: een geldige sessie is geen bewijs dat de
   * eigenaar achter het scherm zit. Na afloop vallen alle andere sessies om en
   * blijft deze staan -- wie dit doet omdat hij vermoedt dat iemand meekijkt,
   * hoort daar niet zelf voor uitgelogd te worden.
   */
  changePassword: (currentPassword: string, password: string) =>
    api.patch("/auth/password", { current_password: currentPassword, password }),

  register: async (name: string, email: string, password: string, _passwordConfirm: string, captcha?: string) => {
    // The control plane sets the HttpOnly session cookie on this response; there
    // is no token to store client-side.
    await api.post("/auth/register", {
      name,
      email,
      password,
      // Sent to the server for server-side Turnstile verification (enforced when
      // the backend has TURNSTILE_SECRET_KEY configured).
      ...(captcha ? { turnstile_token: captcha } : {}),
    });
    return { data: { detail: "ok" } };
  },

  // Login is one step (password → session cookie) unless the account has TOTP on,
  // in which case the control plane withholds the cookie and asks for a code.
  // `verification_required` never comes back on this call — an unconfirmed
  // account is rejected with an error, and the caller reads that flag off the
  // error body, not off a success. It is named here because the login page's
  // one branch switches on it.
  login: async (
    email: string,
    password: string,
    captcha?: string,
    code?: string,
    passkey?: PasskeyAssertion,
  ) => {
    const res = await api.post<LoginResponse>(
      "/auth/login",
      {
        email,
        password,
        // Sent for server-side Turnstile verification (enforced when the backend
        // has TURNSTILE_SECRET_KEY configured) — same contract as register.
        ...(captcha ? { turnstile_token: captcha } : {}),
        ...(code ? { code } : {}),
        ...(passkey ? { passkey } : {}),
      },
    );

    // 2FA gate: the control plane returns { mfa_required: true } and does NOT
    // set the session cookie until a valid second factor is supplied. Everything
    // the login page needs to offer that factor travels along: which methods the
    // account has, and the passkey challenge if there is one.
    if (res.data.mfa_required || res.data.totp_required) {
      return {
        data: {
          mfa_required: true,
          totp_required: Boolean(res.data.totp_required),
          methods: res.data.methods ?? (res.data.totp_required ? ["totp"] : []),
          passkey_challenge: res.data.passkey_challenge ?? null,
        } as LoginResult,
      };
    }

    // On success the control plane sets the HttpOnly session cookie on this response.
    return { data: {} as LoginResult };
  },



  logout: async () => {
    try {
      // The control plane clears the HttpOnly session cookie on this response.
      await api.delete("/auth/logout");
    } finally {
      resetClientState();
    }
    return { data: {} };
  },

  me: async () => {
    const res = await api.get<{ user: BunkUser }>("/auth/me");
    return { data: transformUser(res.data.user) };
  },

  verifyEmail: (token: string) =>
    api.post<{ user: BunkUser }>("/auth/confirm", { token }),

  // Re-sends the confirmation email to the AUTHENTICATED current user (the
  // backend deliberately doesn't take a bare email here, so this can't be used
  // to spam an arbitrary address).
  resendConfirmation: () => api.post<{ detail: string }>("/auth/confirm/resend", {}),

  // The backend always returns 200 with an identical body whether or not `email`
  // matches an account — anti-enumeration contract is "if the address exists, a
  // link was sent", so there is nothing to branch on here either.
  requestPasswordReset: (email: string) =>
    api.post<{ detail: string }>("/auth/password-reset", { email }),

  confirmPasswordReset: (token: string, password: string, passwordConfirm: string) =>
    api.post<{ detail: string }>("/auth/password-reset/confirm", {
      token,
      password,
      password_confirmation: passwordConfirm,
    }),

  passkey: {
    list: async () => (await api.get<{ passkeys: Passkey[] }>("/auth/passkeys")).data.passkeys,
    challenge: async () => (await api.post<PasskeyChallenge>("/auth/passkeys/challenge")).data,
    register: (challenge_id: string, label: string, credential: PublicKeyCredential) => {
      const r = credential.response as AuthenticatorAttestationResponse;
      return api.post<{ passkey: Passkey }>("/auth/passkeys", {
        challenge_id,
        label,
        credential: {
          id: credential.id,
          response: {
            attestationObject: b64url.encode(r.attestationObject),
            clientDataJSON: b64url.encode(r.clientDataJSON),
          },
        },
      });
    },
    remove: (id: string) => api.delete(`/auth/passkeys/${id}`),
    /** Vertaalt het resultaat van navigator.credentials.get() naar wat /auth/login verwacht. */
    assertion: (challenge_id: string, credential: PublicKeyCredential): PasskeyAssertion => {
      const r = credential.response as AuthenticatorAssertionResponse;
      return {
        challenge_id,
        id: credential.id,
        response: {
          authenticatorData: b64url.encode(r.authenticatorData),
          signature: b64url.encode(r.signature),
          clientDataJSON: b64url.encode(r.clientDataJSON),
        },
      };
    },
  },
  totp: {
    setup: () => api.get<{ secret: string; qr_data_url: string }>("/auth/totp/setup"),
    confirm: (code: string) => api.post<{ detail: string }>("/auth/totp/setup", { code }),
    disable: (code: string) => api.delete<{ detail: string }>("/auth/totp/disable", { data: { code } }),
  },
};

// ── Packages ──────────────────────────────────────────────────────────
export const packagesApi = {
  list: async () => {
    const packages = await ensurePackages();
    return { data: { count: packages.length, results: packages } };
  },
};

// ── VPS ───────────────────────────────────────────────────────────────
export interface VpsBackup {
  id: string;
  status: "pending" | "running" | "done" | "failed";
  size_bytes: number | null;
  started_at: string | null;
  finished_at: string | null;
  error: string | null;
}

export interface BunkRegion {
  id: string;
  code: string;
  name: string;
}

export const regionsApi = {
  /**
   * Where a VPS can be placed right now. Only regions with an online node that
   * has capacity come back, so an empty list means "no choice to offer" — not an
   * error, since the control plane still places automatically.
   */
  list: async (): Promise<BunkRegion[]> => {
    const res = await api.get<{ regions: BunkRegion[] }>("/regions");
    return res.data.regions;
  },
};

export const vpsApi = {
  list: async () => {
    // Both at once, not one after the other: the catalog and the VPS list have
    // nothing to say to each other, and awaiting the first before starting the
    // second added a whole round trip to every page that shows a machine.
    //
    // The catalog is cosmetic here (spec→name/price with a "Custom" fallback),
    // so a broken /packages must not take the VPS list down with it — hence the
    // catch, which also has to stay inside the Promise.all or one rejection
    // would discard the other answer.
    const [, res] = await Promise.all([
      ensurePackages().catch(() => []),
      api.get<{ vpses: BunkVps[] }>("/vpses"),
    ]);
    const results = res.data.vpses.map(transformVps);
    return { data: { count: results.length, results } };
  },

  get: async (id: string) => {
    const [, res] = await Promise.all([
      ensurePackages().catch(() => []),
      api.get<{ vps: BunkVps }>(`/vpses/${id}`),
    ]);
    return { data: transformVps(res.data.vps) };
  },

  create: async (data: {
    label?: string;
    package_id: number;
    os: OsChoice;
    region_code?: string;
    /**
     * De klant heeft aangevinkt dat de VPS meteen mag worden aangemaakt en dat
     * hij daarmee zijn herroepingsrecht verliest. Verplicht: de control plane
     * weigert de bestelling zonder, want zonder die bevestiging loopt er
     * veertien dagen bedenktijd over een dienst die al draait.
     */
    immediate_delivery_consent: boolean;
  }) => {
    const packages = await ensurePackages();
    const pkg = packages.find((p) => p.id === data.package_id);
    if (!pkg) throw new Error("Onbekend pakket.");
    const res = await api.post<{ vps: BunkVps }>("/vpses", {
      name: data.label || `vps-${Date.now()}`,
      vcpu: pkg.cpu_cores,
      ram_mb: pkg.ram_gb * 1024,
      disk_gb: pkg.disk_gb,
      // Omitted entirely when the customer has no preference: the control plane
      // then places the VPS on the emptiest machine in the fleet. Sending a
      // region we guessed would override that with a worse answer.
      ...(data.region_code ? { region_code: data.region_code } : {}),
      immediate_delivery_consent: data.immediate_delivery_consent,
    });
    return { data: transformVps(res.data.vps) };
  },

  credentials: async (id: string): Promise<{ data: VpsCredentials }> => {
    const res = await api.get<{ vps: BunkVps }>(`/vpses/${id}`);
    return {
      data: {
        ip_address: res.data.vps.ip_address,
        ssh_port: res.data.vps.ssh_port ?? null,
        ssh_username: "root",
        sudo_password: null,
      },
    };
  },

  /** A VPS's restore points, newest first. Failures are listed too — they are news. */
  backups: async (id: string): Promise<VpsBackup[]> =>
    (await api.get<{ backups: VpsBackup[] }>(`/vpses/${id}/backups`)).data.backups,
  /**
   * Start nu een back-up, buiten het nachtelijke schema om. Het moment waarop je
   * er een wilt is vlak vóór iets engs, en dan is "vannacht" geen antwoord.
   */
  backupNow: (id: string) => api.post(`/vpses/${id}/backups`),

  /**
   * Roll a VPS back to one of its restore points. Destructive: everything
   * written since that backup is gone.
   */
  restore: (id: string, backupId: string) =>
    api.post(`/vpses/${id}/backups/${backupId}/restore`),

  delete: (id: string) => api.delete(`/vpses/${id}`),
  start: (id: string) => api.post<{ detail: string }>(`/vpses/${id}/start`),
  stop: (id: string) => api.post<{ detail: string }>(`/vpses/${id}/stop`),
  /**
   * Herstart van binnenuit: het besturingssysteem wordt gevraagd af te sluiten
   * en komt weer op. Wie de stekker eruit wil trekken doet stop en daarna
   * start -- dat is een andere handeling en ziet er ook anders uit.
   */
  reboot: (id: string) => api.post<{ detail: string }>(`/vpses/${id}/reboot`),
  /**
   * Hernoemt een VPS. Alleen het label dat jij ziet: de naam waaronder de gast
   * op de hypervisor staat blijft wat hij was, want daar herkent de agent zijn
   * machine aan.
   */
  rename: (id: string, name: string) => api.patch(`/vpses/${id}`, { name }),
  // Mint a single-use console ticket (the WS handshake can't carry the bearer).
  consoleTicket: async (id: string): Promise<{ ticket: string }> => {
    const res = await api.post<{ ticket: string }>(`/vpses/${id}/console-ticket`);
    return res.data;
  },
};


// ── Admin (old-stack surface — adapted later; endpoints may 404 on bunk-fleet) ──
// ── Admin panel (session-authenticated, role :admin) ──────────────────────
export interface AdminStats {
  users: { total: number; user: number; admin: number };
  vpses: { total: number; active: number; stopped: number; provisioning: number; failed: number };
  nodes: { total: number; online: number; datacenter: number; community: number };
  credit_outstanding_cents: number;
  /**
   * Hetzelfde bedrag, uitgesplitst naar waar het vandaan komt. De onderdelen
   * tellen op tot het totaal; `verbruikt` is negatief.
   */
  credit_breakdown: {
    betaald: number;
    weggegeven: number;
    handmatig: number;
    verbruikt: number;
    overig: number;
  };
}
export interface AdminUser {
  id: string;
  name: string;
  email: string;
  role: "user" | "admin";
  confirmed: boolean;
  two_factor: boolean;
  inserted_at: string;
  vps_count: number;
  balance_cents: number;
  /**
   * Gezet wanneer dit account is verwijderd maar de administratie moest blijven
   * staan. De rij bestaat dan nog; de persoon erachter niet meer.
   */
  anonymised_at: string | null;
}
export interface AdminVps {
  id: string;
  name: string;
  status: string;
  owner_email: string | null;
  node: string | null;
  region: string | null;
  vcpu: number;
  ram_mb: number;
  disk_gb: number;
  ip_address: string | null;
  inserted_at: string;
}
/** De instellingen die de eigenaar van een node zelf beheert. */
export interface NodeSettings {
  /** Hoeveel van de machine naar de VPS-pool gaat. null of 0 = alles. */
  offer_vcpu: number | null;
  offer_ram_mb: number | null;
  offer_disk_gb: number | null;
  /** Het VMID-blok dat van Bunk is, zodat klant-VPS'en niet tussen de eigen machines komen. */
  vmid_min: number | null;
  vmid_max: number | null;
  /** vCPU's per fysieke core. RAM en schijf worden nooit overboekt. */
  vcpu_oversubscribe: number | null;
  /** Hoe een gast op de hypervisor heet. Moet {id} bevatten. */
  guest_name_pattern: string | null;
  /** De bridge waar de netwerkkaart van een nieuwe VPS aan komt te hangen. */
  vps_bridge: string | null;
  /** 802.1q-tag op die bridge. 0 is untagged en iets anders dan niet ingesteld. */
  vps_vlan: number | null;
}

/** Een node zoals de eigenaar hem ziet: zijn eigen machine, niet de hele vloot. */
export interface MyNode {
  id: string;
  name: string;
  status: string;
  hypervisor: string;
  total_vcpu: number | null;
  total_ram_mb: number | null;
  total_disk_gb: number | null;
  available_vcpu: number | null;
  available_ram_mb: number | null;
  available_disk_gb: number | null;
  reported_avail_vcpu: number | null;
  reported_avail_ram_mb: number | null;
  reported_avail_disk_gb: number | null;
  agent_version: string | null;
  capacity_error: string | null;
  drain_reason: string | null;
  last_heartbeat_at: string | null;
  /** De locatie waar deze machine staat; bepaalt waar klanten hem kunnen kiezen. */
  region_id: string | null;
  /** Diezelfde locatie met naam en al, zodat het scherm hem niet hoeft op te zoeken. */
  region: BunkRegion | null;
  settings: NodeSettings;
}

/** Een locatie zoals de eigenaar van een node hem kan kiezen. */
export interface NodeRegion extends BunkRegion {
  /** Een gesloten locatie staat er alleen bij als er al een eigen node in staat. */
  enabled: boolean;
}

export const nodeApi = {
  /** De nodes die de ingelogde gebruiker beheert. */
  /**
   * De eigen nodes plus de locaties waar ze heen kunnen. Die lijst zit hierin en
   * niet in regionsApi: dat geeft alleen locaties waar nu iets te plaatsen valt,
   * terwijl een eigenaar juist naar een nieuwe, lege locatie moet kunnen.
   */
  mine: async (): Promise<{ nodes: MyNode[]; regions: NodeRegion[] }> =>
    (await api.get<{ nodes: MyNode[]; regions: NodeRegion[] }>("/nodes")).data,

  /**
   * Wijzigt de instellingen van een node. Alleen de eigenaar mag dit; een node
   * van iemand anders geeft 404, want dat hij bestaat is al te veel informatie.
   */
  updateSettings: async (id: string, settings: Partial<NodeSettings>): Promise<MyNode> =>
    (await api.patch<{ node: MyNode }>(`/nodes/${id}/settings`, settings)).data.node,

  /**
   * Draagt een node over aan een andere gebruiker, of haalt de eigenaar eraf.
   * Alleen de eigenaar zelf; een beheerder kan hooguit een node die nog geen
   * eigenaar heeft toewijzen.
   */
  assignOwner: async (id: string, ownerEmail: string | null): Promise<MyNode> =>
    (await api.post<{ node: MyNode }>(`/nodes/${id}/owner`, { owner_email: ownerEmail })).data.node,

  /**
   * Verplaatst de node naar de locatie met deze naam, en maakt die aan als hij
   * nog niet bestaat. De VPS'en erop gaan mee: een regio beschrijft waar de
   * machine fysiek staat, en een VPS kan niet ergens anders staan dan de machine
   * waarop hij draait.
   *
   * Een naam en geen id, zodat een eigenaar niet hoeft te wachten tot iemand
   * anders zijn plaats heeft aangemaakt. Bestaat hij al -- op naam of op code,
   * hoofdletters maken niet uit -- dan gaat de node daarin.
   */
  moveRegion: async (id: string, regionName: string): Promise<MyNode> =>
    (await api.post<{ node: MyNode }>(`/nodes/${id}/region`, { region_name: regionName })).data
      .node,
};

/** Een locatie waar klanten hun VPS kunnen laten draaien. */
export interface AdminRegion {
  id: string;
  code: string;
  name: string;
  /** Uit betekent: wat er draait blijft draaien, er komt niets nieuws bij. */
  enabled: boolean;
  node_count: number;
}

export interface AdminNode {
  id: string;
  name: string;
  status: string;
  /** De kostenplaats die in de verbruiksregels landt — niet wie de node beheert. */
  cost_centre: string | null;
  region: string | null;
  // Null tot de eerste geslaagde heartbeat: een node die nog nooit heeft gemeld
  // heeft geen capaciteit van nul, hij heeft er geen. Het verschil hoort in het
  // scherm te blijven staan, anders lijkt een stille node een lege node.
  total_vcpu: number | null;
  total_ram_mb: number | null;
  total_disk_gb: number | null;
  available_vcpu: number | null;
  available_ram_mb: number | null;
  available_disk_gb: number | null;
  /**
   * Wat de node zelf nog vrij ziet. Plaatsing vereist dat dit én available_*
   * ruimte hebben, dus het laagste van de twee is het bindende getal.
   */
  reported_avail_vcpu: number | null;
  reported_avail_ram_mb: number | null;
  reported_avail_disk_gb: number | null;
  last_heartbeat_at: string | null;
  /** De build die deze node draait; null bij een agent van voor het versiestempel. */
  agent_version: string | null;
  // Gevuld als de agent leeft maar zijn hypervisor niet kan bevragen. Dan is
  // de node online zonder capaciteit, en dit zegt waarom.
  capacity_error: string | null;
  /**
   * Waarom deze node dicht staat, als het systeem hem zelf heeft afgesloten na
   * een mislukte bestelling. Leeg bij een node die met de hand is gesloten.
   */
  drain_reason: string | null;
  /** Wie deze node beheert. Alleen de eigenaar mag de instellingen wijzigen. */
  owner_id: string | null;
  /** Het e-mailadres van die eigenaar, of null als er nog geen is. */
  owner: string | null;
}

/**
 * What the platform is doing, in numbers. Aggregate by construction: the
 * authentication figures are daily totals with nothing behind them, so there is
 * no customer in this payload to show, filter or accidentally log.
 */
export interface AdminMetrics {
  auth: Array<{
    day: string;
    successes: number;
    failures: number;
    registrations: number;
    captcha_refusals: number;
  }>;
  accounts: { total: number; confirmed: number; with_2fa: number };
  nodes: Array<{
    name: string;
    status: string;
    vps_count: number;
    seconds_since_heartbeat: number | null;
    vcpu: { total: number; available: number };
    ram_mb: { total: number; available: number };
    disk_gb: { total: number; available: number };
    headroom_pct: number | null;
  }>;
  commands: Array<{ kind: string; status: string; count: number }>;
  backups: Array<{
    name: string;
    last_success_at: string | null;
    hours_since_success: number | null;
    failures: number;
  }>;
}

export type RevenueTotals = {
  payments: number;
  gross_cents: number;
  net_cents: number;
  vat_cents: number;
};

export type AdminRevenue = {
  from: string;
  to: string;
  vat_percentage: number;
  total: RevenueTotals;
  quarters: (RevenueTotals & { year: number; quarter: number; label: string })[];
  invoices: {
    reference: string;
    paid_at: string | null;
    customer: string;
    gross_cents: number;
    net_cents: number;
    vat_cents: number;
    mollie_payment_id: string | null;
    /** "mollie" = door de betaalprovider bevestigd, "manual" = door een mens. */
    paid_via: string | null;
  }[];
  /** Betaalde opwaarderingen die bewust niet als omzet meetellen, met reden. */
  excluded: {
    reference: string;
    paid_at: string | null;
    customer: string;
    gross_cents: number;
    reason: string;
  }[];
};

export type AdminLedgerEntry = {
  id: string;
  amount_cents: number;
  kind: string;
  description: string | null;
  at: string;
};

export type AdminTopup = {
  id: string;
  reference: string;
  amount_cents: number;
  status: string;
  paid_at: string | null;
  /** false = telt niet als omzet (geen betaling, of met de hand bevestigd). */
  via_provider: boolean;
  /** "mollie" = door de betaalprovider bevestigd, "manual" = door een mens. */
  paid_via: string | null;
  requested_at: string;
};

export type AdminSubscription = {
  id: string;
  vps_id: string | null;
  vps_name: string | null;
  status: string;
  price_monthly: string | null;
  next_billing_date: string | null;
  retry_at: string | null;
  started_at: string | null;
  cancelled_at: string | null;
};

export type AdminUserDetail = {
  user: {
    id: string;
    email: string;
    name: string | null;
    role: string;
    confirmed: boolean;
    totp_enabled: boolean;
    passkeys: number;
    created_at: string;
  };
  balance_cents: number;
  vpses: AdminVps[];
  subscriptions: AdminSubscription[];
  ledger: AdminLedgerEntry[];
  topups: AdminTopup[];
};

export type AdminCommand = {
  id: string;
  kind: string;
  status: string;
  node: string | null;
  vps_id: string | null;
  vps_name: string | null;
  error: string | null;
  at: string;
  delivered_at: string | null;
};

// NOTE: paths are /beheer/* (not /admin/*) — Cloudflare's WAF blocks "/admin"
// URLs with a challenge page before they reach the origin.
export const adminApi = {
  stats: async (): Promise<AdminStats> => (await api.get<AdminStats>("/beheer/stats")).data,
  metrics: async (): Promise<AdminMetrics> =>
    (await api.get<AdminMetrics>("/beheer/metrics")).data,
  users: async (): Promise<AdminUser[]> =>
    (await api.get<{ users: AdminUser[] }>("/beheer/users")).data.users,
  /**
   * Verwijdert een account, of anonimiseert het als er een administratie aan
   * hangt. Het antwoord zegt welke van de twee het is geworden; "verwijderd"
   * melden bij iets wat blijft bestaan zou onwaar zijn.
   */
  deleteUser: async (id: string): Promise<"deleted" | "anonymised"> =>
    (await api.delete<{ result: "deleted" | "anonymised" }>(`/beheer/users/${id}`)).data.result,

  setRole: (id: string, role: "user" | "admin") =>
    api.patch<{ id: string; role: string }>(`/beheer/users/${id}`, { role }),
  addCredit: (id: string, amountCents: number) =>
    api.post<{ id: string; balance_cents: number }>(`/beheer/users/${id}/credit`, {
      amount_cents: amountCents,
    }),
  vpses: async (): Promise<AdminVps[]> =>
    (await api.get<{ vpses: AdminVps[] }>("/beheer/vpses")).data.vpses,
  vpsStart: (id: string) => api.post(`/beheer/vpses/${id}/start`),
  vpsStop: (id: string) => api.post(`/beheer/vpses/${id}/stop`),
  vpsDelete: (id: string) => api.delete(`/beheer/vpses/${id}`),
  regions: async (): Promise<AdminRegion[]> =>
    (await api.get<{ regions: AdminRegion[] }>("/beheer/regions")).data.regions,

  createRegion: async (code: string, name: string): Promise<AdminRegion> =>
    (await api.post<{ region: AdminRegion }>("/beheer/regions", { code, name })).data.region,

  deleteRegion: async (id: string): Promise<void> => {
    await api.delete(`/beheer/regions/${id}`);
  },

  updateRegion: async (
    id: string,
    changes: { name?: string; code?: string; enabled?: boolean },
  ): Promise<AdminRegion> =>
    (await api.patch<{ region: AdminRegion }>(`/beheer/regions/${id}`, changes)).data.region,

  nodes: async (): Promise<AdminNode[]> =>
    (await api.get<{ nodes: AdminNode[] }>("/beheer/nodes")).data.nodes,

  nodeDelete: (id: string) => api.delete(`/beheer/nodes/${id}`),
  userDetail: async (id: string): Promise<AdminUserDetail> =>
    (await api.get<AdminUserDetail>(`/beheer/users/${id}`)).data,
  subscriptions: async () =>
    (
      await api.get<{
        subscriptions: AdminSubscription[];
        active: number;
        past_due: number;
        monthly_total: string;
      }>("/beheer/subscriptions")
    ).data,
  commands: async (status?: string) =>
    (
      await api.get<{ commands: AdminCommand[] }>("/beheer/commands", {
        params: status ? { status } : {},
      })
    ).data.commands,
  revenue: async (from?: string, to?: string): Promise<AdminRevenue> =>
    (
      await api.get<AdminRevenue>("/beheer/omzet", {
        params: { ...(from ? { from } : {}), ...(to ? { to } : {}) },
      })
    ).data,
  /**
   * Close a node to new VPSes. Everything already on it keeps running and keeps
   * being served — this is what you reach for before maintenance, not a way to
   * take a machine down.
   */
  nodeDrain: (id: string) => api.post(`/beheer/nodes/${id}/drain`),
  /**
   * Mint een eenmalig enroll-token voor een nieuwe node. Het pad is /beheer en
   * niet /admin: Cloudflare's WAF blokkeert /admin voor het de origin bereikt.
   */
  createEnrollToken: async (regionCode?: string) =>
    (
      await api.post<{
        enroll_token: string;
        expires_at: string;
        region: string;
        install: string;
      }>("/beheer/enroll-tokens", regionCode ? { region_code: regionCode } : {})
    ).data,
  nodeResume: (id: string) => api.post(`/beheer/nodes/${id}/resume`),
};

// Billing — adapted to bunk-fleet. The overview is derived live from the
// customer's active VPSes and the package catalog (bunk-fleet bills per running
// VPS). bunk-fleet has no invoicing engine yet, so the invoice list is honestly
// empty rather than fabricated; the UI then shows its "no invoices" state.
export interface WalletEntry {
  amount_cents: number;
  kind: string;
  description: string | null;
  inserted_at: string;
}

export interface WalletTopup {
  amount_cents: number;
  status: "pending" | "paid" | "cancelled";
  reference: string;
  inserted_at: string;
}

export interface Wallet {
  balance_cents: number;
  entries: WalletEntry[];
  topups: WalletTopup[];
}

export interface UsageVps {
  vps_id: string;
  name: string;
  seconds: number;
  cost: string;
}

export interface UsageSummary {
  from: string;
  to: string;
  total_seconds: number;
  total_cost: string;
  vpses: UsageVps[];
}

export const billingApi = {
  // The real prepaid-wallet surface (bunk-fleet's actual customer billing model).
  wallet: async (): Promise<{ data: Wallet }> => {
    const res = await api.get<Wallet>("/billing/wallet");
    return { data: res.data };
  },

  usage: async (): Promise<{ data: UsageSummary }> => {
    const res = await api.get<UsageSummary>("/billing/usage");
    return { data: res.data };
  },

  // Start a Mollie top-up; returns the hosted checkout URL to redirect the user to.
  topup: async (
    amountCents: number
  ): Promise<{ checkout_url: string; payment_id: string }> => {
    const res = await api.post<{ checkout_url: string; payment_id: string }>(
      "/billing/topup",
      { amount_cents: amountCents }
    );
    return res.data;
  },

  overview: async (): Promise<{ data: BillingOverview }> => {
    const res = await vpsApi.list();
    const active = res.data.results.filter(
      (v) => v.status === "ACTIVE" || v.status === "STOPPED"
    );
    // Een onbekende prijs telt niet mee in plaats van als nul: het verschil is
    // hier vooral dat `parseFloat("")` NaN geeft, en dan verdwijnt het hele
    // maandbedrag in plaats van één regel. Onbekend komt alleen voor als een
    // pakket uit de catalogus is verwijderd terwijl er nog een VPS op draait;
    // wat er werkelijk is afgeschreven staat in het grootboek, niet hier.
    const monthly = active.reduce((sum, v) => {
      const prijs = parseFloat(v.package?.price_monthly ?? "");
      return Number.isFinite(prijs) ? sum + prijs : sum;
    }, 0);
    const now = new Date();
    const next = new Date(now.getFullYear(), now.getMonth() + 1, 1);
    return {
      data: {
        open_amount: "0.00",
        open_invoice_count: 0,
        monthly_cost: monthly.toFixed(2),
        active_subscriptions: active.length,
        next_invoice_date: next.toISOString().slice(0, 10),
      },
    };
  },
};

