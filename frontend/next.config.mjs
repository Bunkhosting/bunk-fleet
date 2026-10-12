/** @type {import('next').NextConfig} */

// Fallbacks are the live origin; api.bunkhosting.nl has no DNS/tunnel.
//
// LET OP: alles met `NEXT_PUBLIC_` wordt bij het BOUWEN in de clientbundel
// gebakken, niet bij het starten gelezen. Deze waarde is dus geen
// omgevingsvariabele maar een constante die per image vastligt. Verhuist het
// domein, of komt er een tweede omgeving bij, dan is dat een herbouw van de
// frontend en niet een `-e` erbij in het uitrolscript. Dat is geen fout -- zo
// werkt Next -- maar het is precies het soort ding waarvan je op het verkeerde
// moment ontdekt dat het zo werkt.
const API_URL = process.env.NEXT_PUBLIC_API_URL || "https://app.bunkhosting.nl";
const WS_URL  = (process.env.NEXT_PUBLIC_WS_URL  || "wss://app.bunkhosting.nl").replace(/^http/, "ws");
// No trailing slash: that was a Django-era path, and the endpoint it pointed at
// did not exist — every violation report a browser sent got a 404, so the
// reporting was decoration. This matches the route the control plane serves.
const CSP_REPORT_URI = `${API_URL}/api/v1/security/csp-report`;

// The Content-Security-Policy is NOT here: it carries a per-request nonce and
// therefore lives in src/proxy.ts. A policy shipped from this file would be
// static, and a static policy has to allow 'unsafe-inline' for Next's hydration
// bootstrap — which is exactly the thing worth getting rid of.
//
// Only the headers that are specific to the HTML this app serves. Everything
// else — frame options, nosniff, HSTS, referrer policy, permissions policy,
// COOP — is set once at the nginx edge, which also fronts the API and is
// therefore the only layer that can cover every response. Setting them in both
// places is how a policy drifts apart: you change one and the other keeps
// answering.
const securityHeaders = [
  // Reporting API (modern). Browsers die alleen report-uri ondersteunen
  // vallen terug op de directive 'report-uri' verderop in de CSP.
  {
    key: "Report-To",
    value: JSON.stringify({
      group: "csp-endpoint",
      max_age: 10886400,
      endpoints: [{ url: CSP_REPORT_URI }],
    }),
  },
];

const nextConfig = {
  typescript: { ignoreBuildErrors: false },

  // Geen `eslint`-sleutel meer. Die stond op `ignoreDuringBuilds: true`, maar
  // Next 16 lint sowieso niet meer tijdens `next build` en weigert de sleutel.
  // Lint is alleen nog de eigen CI-stap `npx eslint . --max-warnings 0`. Een
  // lokale `npm run build` is dus groen terwijl lint rood kan staan; weet het.

  // ALLEEN voor `next dev`. In productie staat nginx ervoor en die pakt
  // `/api/v1/` af voordat Next het ooit ziet (zie edge.conf), dus deze regel
  // doet daar niets.
  //
  // Hij blijft staan omdat hij lokaal ontwikkelen zonder nginx mogelijk maakt.
  // Hij krijgt dit commentaar omdat hij anders een val is: wie over een half
  // jaar een routeringsprobleem in de API zoekt, vindt deze regel als eerste,
  // past hem aan, rolt uit, en er verandert niets.
  async rewrites() {
    const target = process.env.BUNK_API_URL || "http://bf-prod-cp:4000";
    return [{ source: "/api/v1/:path*", destination: `${target}/api/v1/:path*` }];
  },
  output: "standalone",

  // Geen `X-Powered-By: Next.js`. Het vertelt een aanvaller welk framework en
  // daarmee welke bekende lekken hij als eerste kan proberen, en het levert
  // niemand iets op. Klein, maar het is gratis.
  poweredByHeader: false,

  async headers() {
    return [
      {
        source: "/:path*",
        headers: securityHeaders,
      },
    ];
  },
};

export default nextConfig;
