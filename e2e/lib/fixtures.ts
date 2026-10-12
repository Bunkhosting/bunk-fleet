import { test as base, expect, request as pwRequest } from "@playwright/test";
import { APP } from "./targets";

/**
 * De suite draait tegen productie, en op dezelfde machine als productie.
 * Daarom een wachter die vóór elk testblok kijkt of de dienst nog vlot
 * antwoordt. Zakt hij weg, dan stopt de suite met werk maken en wacht tot het
 * herstelt — een test die draait terwijl de machine op zijn knieën ligt meet
 * zijn eigen ruis, en erger: hij houdt de dienst daar.
 *
 * Wat hij meet wordt ook bewaard: dat een browsertest de dienst kan vertragen
 * is zelf een bevinding over de capaciteit van deze machine, geen bijzaak.
 */

const DREMPEL_MS = 1000; // healthz hoort binnen een seconde terug te zijn
const HERHAAL_MS = 20_000; // niet vaker dan dit meten; anders word je het verkeer
const MAX_WACHT_MS = 180_000; // zo lang wachten we op herstel, daarna geven we op

let laatsteMeting = 0;
let laatsteWaarde: { ms: number; status: number } | null = null;

export const trageMomenten: Array<{ wanneer: string; ms: number; status: number }> = [];

async function meetHealthz(): Promise<{ ms: number; status: number }> {
  const ctx = await pwRequest.newContext();
  const t0 = Date.now();
  try {
    const res = await ctx.get(`${APP}/healthz`, { timeout: 15_000 });
    return { ms: Date.now() - t0, status: res.status() };
  } catch {
    return { ms: Date.now() - t0, status: 0 };
  } finally {
    await ctx.dispose();
  }
}

/**
 * Wacht tot /healthz weer binnen de drempel antwoordt. Geeft terug hoe lang er
 * gewacht is; 0 betekent dat het meteen goed was.
 */
export async function wachtTotGezond(): Promise<number> {
  const begin = Date.now();
  for (;;) {
    const m = await meetHealthz();
    laatsteMeting = Date.now();
    laatsteWaarde = m;
    if (m.status === 200 && m.ms <= DREMPEL_MS) return Date.now() - begin;
    // Een 4xx is geen trage dienst maar een weigering: bijna altijd Cloudflare
    // die het adres van deze runner niet binnenlaat. Wachten helpt dan niet;
    // de eerste run vanaf GitHub stond zo twintig minuten te pauzeren tot de
    // time-out, met 45 seconden per test. Meteen stoppen met wat er aan de hand is.
    if (m.status >= 400 && m.status < 500) {
      throw new Error(
        `/healthz gaf ${m.status}: de edge weigert dit adres, de dienst zelf is niet gemeten`,
      );
    }

    trageMomenten.push({ wanneer: new Date().toISOString(), ms: m.ms, status: m.status });
    console.warn(
      `[gezondheidswacht] /healthz gaf ${m.status} in ${m.ms} ms (drempel ${DREMPEL_MS} ms) — pauzeren`,
    );
    if (Date.now() - begin > MAX_WACHT_MS) return Date.now() - begin;
    await new Promise((r) => setTimeout(r, 5000));
  }
}

export const test = base.extend<{ gezondheidswacht: void }>({
  gezondheidswacht: [
    async ({}, use) => {
      // Niet bij élke test opnieuw meten: dan is de wachter zelf het verkeer.
      if (Date.now() - laatsteMeting > HERHAAL_MS) {
        const gewacht = await wachtTotGezond();
        if (gewacht > 0) {
          console.warn(`[gezondheidswacht] ${Math.round(gewacht / 1000)} s gewacht op herstel`);
        }
      }
      await use();
    },
    { auto: true },
  ],
});

export { expect, pwRequest };

/** Voor een rapport aan het eind: wat hebben we onderweg zien wegzakken? */
export function gezondheidsverslag(): string {
  if (!trageMomenten.length) {
    return `geen enkele trage of mislukte /healthz tijdens de run (laatste meting: ${
      laatsteWaarde ? `${laatsteWaarde.status} in ${laatsteWaarde.ms} ms` : "geen"
    })`;
  }
  return `${trageMomenten.length}x trage of mislukte /healthz: ${trageMomenten
    .map((t) => `${t.wanneer} ${t.status} in ${t.ms} ms`)
    .join("; ")}`;
}
