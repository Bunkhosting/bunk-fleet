import { test, expect, pwRequest } from "../lib/fixtures";
import { APP } from "../lib/targets";
import { collectProblems, schoon, summarize, verwachtSchoon } from "../lib/collect";
import { ga } from "../lib/navigatie";
import * as fs from "node:fs";
import * as path from "node:path";

/**
 * 10. De ingelogde kant, in een echte browser.
 *
 * Alles wat hierachter zit was nooit door een test gelopen: het dashboard, de
 * VPS-lijst, facturatie, beveiliging. Dat is de helft van het product waar een
 * klant zijn tijd doorbrengt.
 *
 * ## Waarom niet via het inlogformulier
 *
 * Daar staat Turnstile voor, en dat bedient een headless browser niet. Inloggen
 * gebeurt daarom via de API -- hetzelfde verzoek dat het formulier doet -- en de
 * sessiecookie gaat daarna de browser in. Wat hier getest wordt is dus niet
 * "kun je inloggen" maar "wat ziet iemand die ingelogd is", en dat is precies
 * het stuk dat nog ontbrak.
 *
 * ## Grens
 *
 * Alleen lezen. Er wordt niets besteld, niets hernoemd en niets verwijderd. De
 * knoppen die dat doen worden wel gecontroleerd op hun aanwezigheid en op of ze
 * bereikbaar zijn, maar er wordt niet op geklikt.
 */

const WACHTWOORD_BESTAND = path.join(__dirname, "..", ".testpw");
const EMAIL = "test@bunkhosting.nl";

function wachtwoord(): string | null {
  try {
    return fs.readFileSync(WACHTWOORD_BESTAND, "utf8").trim() || null;
  } catch {
    return null;
  }
}

/** De sessiecookie van het testaccount, of null als er geen wachtwoord is. */
async function sessieCookie(): Promise<{ name: string; value: string } | null> {
  const pw = wachtwoord();
  if (!pw) return null;

  const ctx = await pwRequest.newContext();
  const res = await ctx.post(`${APP}/api/v1/auth/login`, {
    data: { email: EMAIL, password: pw },
  });
  if (!res.ok()) return null;

  const koppen = res.headersArray().filter((h) => h.name.toLowerCase() === "set-cookie");
  for (const h of koppen) {
    const m = h.value.match(/^([^=]+)=([^;]+)/);
    if (m && m[1].includes("session")) return { name: m[1], value: m[2] };
  }
  return null;
}

test.describe("ingelogd", () => {
  test.beforeEach(async ({ context }) => {
    const cookie = await sessieCookie();
    test.skip(
      cookie === null,
      `geen testaccount: zet het wachtwoord in e2e/.testpw (zie e2e/api/README.md)`,
    );
    await context.addCookies([
      { ...cookie!, domain: new URL(APP).hostname, path: "/", httpOnly: true, secure: true },
    ]);
  });

  const PAGINAS = [
    { naam: "dashboard", pad: "/dashboard" },
    { naam: "VPS-lijst", pad: "/dashboard/vps" },
    { naam: "nieuwe VPS", pad: "/dashboard/vps/new" },
    { naam: "facturatie", pad: "/dashboard/billing" },
    { naam: "beveiliging", pad: "/dashboard/beveiliging" },
    { naam: "nodes", pad: "/dashboard/nodes" },
  ];

  for (const { naam, pad } of PAGINAS) {
    test(`${naam} laadt zonder fouten voor een ingelogde klant`, async ({ page }, testInfo) => {
      const problemen = collectProblems(page);
      const res = await ga(page, `${APP}${pad}`);

      expect(res?.status(), `${pad} gaf ${res?.status()}`).toBeLessThan(400);

      // Niet op de loginpagina belanden: dat zou betekenen dat de sessie niet
      // meetelt, en dan meet de rest van deze test niets.
      expect(page.url(), `${pad} stuurde door naar ${page.url()}`).not.toContain("/login");

      // Geen rauwe foutcode op het scherm. Een klant hoort "er ging iets mis" te
      // lezen, geen `internal_error` of een stuk JSON.
      const tekst = await page.locator("body").innerText();
      for (const lek of ["internal_error", "invalid_vps", "not_found", "Traceback", "Ecto."]) {
        expect.soft(tekst, `${pad} toont de rauwe code ${lek}`).not.toContain(lek);
      }

      verwachtSchoon(problemen, pad);
      if (!schoon(problemen)) {
        testInfo.attach(`${naam}-problemen.json`, {
          body: summarize(problemen),
          contentType: "application/json",
        });
      }
    });
  }

  test("de VPS-lijst zegt iets bruikbaars als er geen VPS is", async ({ page }) => {
    await ga(page, `${APP}/dashboard/vps`);
    const tekst = (await page.locator("body").innerText()).toLowerCase();

    // Een leeg scherm is geen antwoord. Er hoort iets te staan dat zegt dat er
    // niets is én hoe je er een krijgt.
    expect.soft(tekst.length, "de VPS-pagina is leeg").toBeGreaterThan(80);
    expect
      .soft(/geen vps|nog geen|aanvragen|bestellen|nieuwe vps/.test(tekst), "geen wegwijzer")
      .toBe(true);
  });

  test("het tegoed staat op de facturatiepagina", async ({ page }) => {
    await ga(page, `${APP}/dashboard/billing`);
    const tekst = await page.locator("body").innerText();

    // Een bedrag in euro's, in welke notatie dan ook.
    expect.soft(/€\s?\d/.test(tekst), "geen bedrag op de facturatiepagina").toBe(true);
  });

  test("het beheerpaneel blijft dicht voor een gewone klant", async ({ page }) => {
    const res = await ga(page, `${APP}/dashboard/beheer`);
    const status = res?.status() ?? 0;
    const url = page.url();

    // Of een 4xx, of doorgestuurd weg van het paneel. Wat er niet mag is een
    // beheerscherm met gegevens van andere klanten erin.
    const geweerd = status >= 400 || !url.includes("/beheer");
    const tekst = await page.locator("body").innerText();
    const toontGegevens = /klanten|gebruikers|totaal tegoed|alle vps/i.test(tekst);

    expect(geweerd || !toontGegevens, `beheerpaneel toonde gegevens op ${url}`).toBe(true);
  });
});
