import { test, expect, pwRequest } from "../lib/fixtures";
import type { Page } from "@playwright/test";
import { APP } from "../lib/targets";
import { ga } from "../lib/navigatie";
import * as fs from "node:fs";
import * as path from "node:path";

/**
 * 11. De passkey-ceremonie, in een echte browser.
 *
 * Registreren (navigator.credentials.create) en inloggen
 * (navigator.credentials.get) waren nog nooit door een browser gelopen; de
 * unit- en API-tests sturen zelf bytes naar de server. Hier doet Chromium het
 * echte werk, met een virtuele authenticator (CDP `WebAuthn.*`) in plaats van
 * een vingerafdruk.
 *
 * ## Grens
 *
 * Alleen het testaccount, en netto niets: er komt precies één passkey bij en
 * die gaat er aan het eind weer af, ook als een tussenstap faalt (finally).
 * Verwijderen vraagt het huidige wachtwoord, net als in de UI.
 *
 * ## Login
 *
 * De eerste sessie komt via de API (zoals ingelogd.spec.ts; geen Turnstile in
 * een headless browser). Het tweede inloggen gaat wél via het formulier: zodra
 * het account een passkey heeft geeft het wachtwoord een challenge terug en
 * verschijnt de knop "Inloggen met passkey" -- dat is wat hier getest wordt.
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

async function sessieCookie(pw: string): Promise<{ name: string; value: string } | null> {
  const ctx = await pwRequest.newContext();
  try {
    const res = await ctx.post(`${APP}/api/v1/auth/login`, {
      data: { email: EMAIL, password: pw },
      headers: { Origin: APP },
    });
    if (!res.ok()) return null;
    for (const h of res.headersArray().filter((k) => k.name.toLowerCase() === "set-cookie")) {
      const m = h.value.match(/^([^=]+)=([^;]+)/);
      if (m && m[1].includes("session")) return { name: m[1], value: m[2] };
    }
    return null;
  } finally {
    await ctx.dispose();
  }
}

/** Inloggen via het formulier met wachtwoord + passkey (de tweede factor). */
async function loginMetPasskey(page: Page, pw: string): Promise<void> {
  await ga(page, `${APP}/login`);
  await page.getByLabel("E-mailadres").fill(EMAIL);
  await page.getByLabel("Wachtwoord", { exact: true }).fill(pw);
  await page.getByRole("button", { name: "Inloggen", exact: true }).click();
  await page.getByRole("button", { name: "Inloggen met passkey" }).click();
  await expect(page).toHaveURL(/\/dashboard/);
}

test.describe.serial("passkey", () => {
  test("toevoegen, inloggen en verwijderen met een virtuele authenticator", async ({
    page,
    context,
    browserName,
  }) => {
    test.setTimeout(120_000);
    test.skip(browserName !== "chromium", "de virtuele authenticator is een Chromium-CDP-functie");

    const pw = wachtwoord();
    test.skip(pw === null, "geen testaccount: zet het wachtwoord in e2e/.testpw (zie e2e/api/README.md)");
    const cookie = await sessieCookie(pw!);
    test.skip(cookie === null, "inloggen van het testaccount via de API lukte niet");

    await context.addCookies([
      { ...cookie!, domain: new URL(APP).hostname, path: "/", httpOnly: true, secure: true },
    ]);

    const cdp = await context.newCDPSession(page);
    await cdp.send("WebAuthn.enable");
    await cdp.send("WebAuthn.addVirtualAuthenticator", {
      options: {
        protocol: "ctap2",
        transport: "internal",
        hasResidentKey: true,
        hasUserVerification: true,
        isUserVerified: true,
        automaticPresenceSimulation: true,
      },
    });

    const label = `e2e-${Date.now()}`;
    let toegevoegd = false;
    let verwijderd = false;

    try {
      // 1. toevoegen
      await ga(page, `${APP}/dashboard/beveiliging`);
      await page.getByRole("button", { name: "Passkey toevoegen" }).click();
      const naamDialoog = page.getByRole("dialog");
      await naamDialoog.getByLabel("Naam").fill(label);
      await naamDialoog.getByRole("button", { name: "Verder" }).click();
      toegevoegd = true; // vanaf hier kan de server hem hebben
      await expect(page.getByText(label, { exact: true })).toBeVisible();

      // 2. uitloggen
      await page.getByRole("button", { name: "Uitloggen" }).click();
      await expect(page).toHaveURL(/\/login/);

      // 3. inloggen met de passkey
      await loginMetPasskey(page, pw!);

      // 4. verwijderen via de UI
      await ga(page, `${APP}/dashboard/beveiliging`);
      await expect(page.getByText(label, { exact: true })).toBeVisible();
      await page.getByRole("button", { name: `Passkey ${label} verwijderen` }).click();
      const wwDialoog = page.getByRole("dialog");
      await wwDialoog.getByLabel("Huidig wachtwoord").fill(pw!);
      await wwDialoog.getByRole("button", { name: "Passkey verwijderen", exact: true }).click();
      await expect(page.getByText(label, { exact: true })).toHaveCount(0);
      verwijderd = true;
    } finally {
      if (toegevoegd && !verwijderd) {
        // Opruimen via de API met de sessie van de browser; is die weg, dan
        // eerst opnieuw inloggen met de passkey die nog bestaat.
        const url = `${APP}/api/v1/auth/passkeys`;
        let lijst = await page.request.get(url);
        if (!lijst.ok()) {
          await loginMetPasskey(page, pw!);
          lijst = await page.request.get(url);
        }
        const body = (await lijst.json()) as { passkeys?: Array<{ id: string; label: string }> };
        const mijn = (body.passkeys ?? []).find((p) => p.label === label);
        if (mijn) {
          const res = await page.request.delete(`${url}/${mijn.id}`, {
            data: { current_password: pw },
            headers: { Origin: APP },
          });
          expect(
            res.ok(),
            `opruimen van passkey ${label} mislukte (${res.status()}): verwijder hem handmatig`,
          ).toBe(true);
        }
      }
    }
  });
});
