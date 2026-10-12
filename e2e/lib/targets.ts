export const APP = process.env.BUNK_APP_URL || "https://app.bunkhosting.nl";
export const WWW = process.env.BUNK_WWW_URL || "https://bunkhosting.nl";

/** Publieke pagina's op het klantpaneel: bereikbaar zonder sessie. */
export const APP_PUBLIC_PATHS = ["/login", "/register", "/forgot-password"];

/**
 * Alles onder /dashboard komt uit frontend/src/app/dashboard. De opdracht noemt
 * /vps, /beheer en /nodes; die bestaan niet als toplevel-route (404), de echte
 * paden zitten onder /dashboard. Beide staan hier, zodat de test dat verschil
 * ook laat zien in plaats van het stilzwijgend goed te praten.
 */
export const APP_PROTECTED_PATHS = [
  "/dashboard",
  "/dashboard/vps",
  "/dashboard/vps/new",
  "/dashboard/nodes",
  "/dashboard/billing",
  "/dashboard/beveiliging",
  "/dashboard/beheer",
  "/dashboard/beheer/vps",
  "/dashboard/beheer/users",
  "/dashboard/beheer/nodes",
  "/dashboard/beheer/regios",
  "/dashboard/beheer/omzet",
  "/dashboard/beheer/metrics",
  "/dashboard/beheer/activiteit",
  "/dashboard/beheer/abonnementen",
];

/** Toplevel-paden die de opdracht noemt; hier om vast te leggen wat ze doen. */
export const APP_LEGACY_PATHS = ["/vps", "/beheer", "/nodes"];

/**
 * API's die zonder token 401 horen te geven. /packages staat er bewust NIET
 * bij: die is publiek bedoeld (de prijstabel op de loginpagina leest hem).
 */
export const API_AUTH_REQUIRED = [
  "/api/v1/vpses",
  "/api/v1/vpses/1",
  "/api/v1/vpses/1/backups",
  "/api/v1/auth/me",
  "/api/v1/regions",
  "/api/v1/nodes",
  "/api/v1/billing/wallet",
  "/api/v1/billing/usage",
  "/api/v1/auth/passkeys",
  "/api/v1/auth/totp/setup",
  // Beheerderspaneel: eigen sessietoken + :admin-rol. Zonder token net zo goed 401.
  "/api/v1/beheer/stats",
  "/api/v1/beheer/users",
  "/api/v1/beheer/vpses",
  "/api/v1/beheer/nodes",
  "/api/v1/beheer/omzet",
  "/api/v1/beheer/metrics",
];

/**
 * De node-API (agent-token) en de oude admin-API. /v1/* hangt wél aan de edge,
 * /admin/v1/* bewust niet — dat hoort dus de frontend-404 te geven en niet de
 * control plane te bereiken. Sinds 2026-10 vraagt /admin/v1 een
 * beheerderssessie in plaats van een gedeeld geheim, maar ook zo hoort hij van
 * buiten onzichtbaar te blijven.
 */
export const API_NODE_PATHS = ["/v1/commands", "/v1/port-forwards"];
export const API_ADMIN_V1 = ["/admin/v1/nodes", "/admin/v1/vpses", "/admin/v1/credits"];

export const API_PUBLIC = ["/api/v1/packages"];
