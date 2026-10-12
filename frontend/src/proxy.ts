import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

// Fallbacks are the live origin; api.bunkhosting.nl has no DNS/tunnel.
const API_URL = process.env.NEXT_PUBLIC_API_URL || "https://app.bunkhosting.nl";
const WS_URL = (process.env.NEXT_PUBLIC_WS_URL || "wss://app.bunkhosting.nl").replace(/^http/, "ws");
// No trailing slash: that was a Django-era path, and the endpoint it pointed at
// did not exist — every violation report a browser sent got a 404, so the
// reporting was decoration. This matches the route the control plane serves.
const CSP_REPORT_URI = `${API_URL}/api/v1/security/csp-report`;

/**
 * The Content-Security-Policy, built fresh per request around a one-time nonce.
 *
 * It lives here rather than in next.config.mjs because a nonce cannot be static:
 * a policy shipped from the config would have to allow 'unsafe-inline' to let
 * Next's hydration bootstrap run, and 'unsafe-inline' is the single thing that
 * decides whether an XSS in this app executes or does nothing.
 *
 * `'strict-dynamic'` lets a script the nonce already trusts load more scripts —
 * that is how Next's chunks and the Turnstile widget (which does
 * `document.createElement("script")`) still load. Browsers that only speak CSP2
 * ignore 'strict-dynamic' and fall back to the nonce plus the host allowlist,
 * which is why challenges.cloudflare.com stays listed.
 *
 * - style-src: 'unsafe-inline' is still required — Tailwind and the font loader
 *   both emit inline <style>, and CSS has no equivalent of strict-dynamic.
 * - img-src: data: for TOTP QR codes, blob: for the xterm canvas. No remote
 *   images are ever loaded, so no https: wildcard — that shuts off
 *   tracking-pixel and exfiltration vectors.
 * - connect-src: API + WebSocket + Turnstile + the report endpoint.
 * - worker-src: blob: for the xterm.js web worker.
 */
function contentSecurityPolicy(nonce: string): string {
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic' https://challenges.cloudflare.com`,
    // Geen fonts.googleapis.com meer. `next/font/google` haalt de fonts bij de
    // BUILD op en serveert ze daarna van onze eigen origin
    // (/_next/static/media/*.woff2); er gaat in productie geen enkel verzoek
    // naar Google. Die twee uitzonderingen verruimden de policy dus zonder dat
    // er iets langskwam -- en ze hielden Google Ireland op de verwerkerslijst
    // voor iets wat het niet doet.
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    `connect-src 'self' ${API_URL} ${WS_URL} https://challenges.cloudflare.com`,
    "frame-src 'self' https://challenges.cloudflare.com",
    "frame-ancestors 'none'",
    // No <object>/<embed>/<applet> anywhere; block them outright.
    "object-src 'none'",
    "worker-src blob:",
    "base-uri 'self'",
    "form-action 'self'",
    "upgrade-insecure-requests",
    `report-uri ${CSP_REPORT_URI}`,
    "report-to csp-endpoint",
  ].join("; ");
}

// Auth is an HttpOnly `bunk_session` cookie set by the control plane. This
// proxy only checks its PRESENCE for UX redirects (avoiding a flash of
// protected UI); the real authorization boundary is the API, which validates the
// session on every request. The proxy runs server-side, so it can read the
// HttpOnly cookie even though client JS cannot.
//
// Dit heette tot Next 16 `middleware` (src/middleware.ts). Next 16 hernoemde de
// conventie naar `proxy` en draait hem altijd op de Node.js-runtime, niet meer
// op edge; een `runtime`-export is hier verboden en laat de build falen. Niets
// hieronder hangt van de runtime af: `crypto.randomUUID`, `Headers` en
// `NextResponse` zijn in Node 22 dezelfde Web-API's.
export function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;
  const isLoggedIn = Boolean(request.cookies.get("bunk_session")?.value);

  const nonce = crypto.randomUUID().replace(/-/g, "");
  const csp = contentSecurityPolicy(nonce);

  // Send logged-in users away from the auth-only pages.
  const authOnlyPaths = ["/login", "/register", "/forgot-password"];
  if (authOnlyPaths.includes(pathname) && isLoggedIn) {
    return withCsp(NextResponse.redirect(new URL("/dashboard", request.url)), csp);
  }

  // Protect dashboard routes.
  if (pathname.startsWith("/dashboard") && !isLoggedIn) {
    const loginUrl = new URL("/login", request.url);
    loginUrl.searchParams.set("next", pathname);
    return withCsp(NextResponse.redirect(loginUrl), csp);
  }
  // /dashboard/beheer/* (admin panel) is authorized server-side: every
  // /api/v1/admin/* call requires the :admin role (403 otherwise) and the pages
  // wrap in <AdminGuard>. An opaque token can't carry the role, so we don't gate
  // it here.

  // Next reads the nonce off the REQUEST header and stamps it onto the inline
  // scripts it renders; the response header is what the browser enforces. Both
  // have to be the same string.
  const headers = new Headers(request.headers);
  headers.set("x-nonce", nonce);
  headers.set("Content-Security-Policy", csp);

  return withCsp(NextResponse.next({ request: { headers } }), csp);
}

// A redirect carries no scripts, but it still gets a policy: a response without
// one is a response an attacker can reason about.
function withCsp(response: NextResponse, csp: string): NextResponse {
  response.headers.set("Content-Security-Policy", csp);
  return response;
}

export const config = {
  // Everything that can carry HTML. Static assets and the image optimizer are
  // excluded: they are not documents, and minting a nonce per file request buys
  // nothing.
  matcher: [
    "/((?!_next/static|_next/image|favicon.svg|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)",
  ],
};
