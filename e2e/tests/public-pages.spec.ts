import { test, expect } from "../lib/fixtures";
import { collectProblems, schoon, summarize, verwachtSchoon } from "../lib/collect";
import { APP, WWW, APP_PUBLIC_PATHS } from "../lib/targets";
import { ga } from "../lib/navigatie";

/**
 * 1. Beide domeinen laden schoon: geen JS-console-errors, geen mislukte
 *    requests, geen 4xx/5xx op subresources, geen mixed content.
 */

const PAGES: Array<{ name: string; url: string }> = [
  { name: "marketingsite", url: `${WWW}/` },
  { name: "app root (redirect naar /login)", url: `${APP}/` },
  ...APP_PUBLIC_PATHS.map((p) => ({ name: `app ${p}`, url: `${APP}${p}` })),
];

for (const { name, url } of PAGES) {
  test(`${name} laadt zonder console-errors of gebroken requests`, async ({ page }, testInfo) => {
    const problems = collectProblems(page);

    const res = await ga(page, url);
    expect(res, `geen response voor ${url}`).not.toBeNull();
    expect.soft(res!.status(), `HTTP-status van ${url}`).toBeLessThan(400);

    // Turnstile laadt asynchroon; geef het even, anders meet je de leegte ervoor.
    await page.waitForTimeout(2500);

    await testInfo.attach(`${name}.png`, {
      body: await page.screenshot({ fullPage: true }),
      contentType: "image/png",
    });

    verwachtSchoon(problems, url);

    if (!schoon(problems)) {
      testInfo.attach("problems.json", { body: summarize(problems), contentType: "application/json" });
    }
  });
}

test("app root stuurt een anonieme bezoeker naar /login", async ({ page }) => {
  const res = await page.goto(`${APP}/`);
  expect(res!.status()).toBe(200); // na de redirect
  expect(page.url()).toContain("/login");
});

test("marketingsite linkt naar het klantpaneel en die link werkt", async ({ page }) => {
  await page.goto(`${WWW}/`, { waitUntil: "domcontentloaded" });
  const links = await page.locator('a[href*="app.bunkhosting.nl"]').all();
  expect(links.length, "marketingsite heeft geen enkele link naar app.bunkhosting.nl").toBeGreaterThan(0);

  const hrefs = [...new Set(await Promise.all(links.map((l) => l.getAttribute("href"))))];
  for (const href of hrefs) {
    if (!href) continue;
    const res = await page.request.get(href, { maxRedirects: 5 });
    expect.soft(res.status(), `link ${href} vanaf de marketingsite`).toBeLessThan(400);
  }
});
