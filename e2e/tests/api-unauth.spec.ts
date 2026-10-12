import { test, expect, pwRequest } from "../lib/fixtures";
import {
  APP,
  API_AUTH_REQUIRED,
  API_PUBLIC,
  API_NODE_PATHS,
  API_ADMIN_V1,
} from "../lib/targets";

/**
 * 5. API zonder token.
 *
 * Alleen GET's, en alleen op endpoints die zonder geldig token per definitie
 * niets kunnen veranderen. Geen POST/DELETE op productie.
 */

// Signalen dat er meer teruggaat dan "je mag hier niet komen".
const LEAK_PATTERNS: Array<[RegExp, string]> = [
  [/Elixir\./, "Elixir-modulenaam"],
  [/\bPhoenix\b/, "Phoenix"],
  [/\bEcto\b/, "Ecto"],
  [/stacktrace/i, "stacktrace"],
  [/\.ex:\d+/, "bronbestand + regelnummer"],
  [/lib\/control_plane/, "pad in de repo"],
  [/Postgrex/, "databasedriver"],
  [/FunctionClauseError|MatchError|ArgumentError/, "Elixir-exceptie"],
];

for (const path of API_AUTH_REQUIRED) {
  test(`GET ${path} zonder token geeft 401 met een nette JSON-fout`, async ({}, testInfo) => {
    const ctx = await pwRequest.newContext();
    const res = await ctx.get(`${APP}${path}`);
    const body = await res.text();
    testInfo.attach(`${path.replace(/\//g, "_")}.txt`, {
      body: `${res.status()}\n${JSON.stringify(res.headers(), null, 2)}\n\n${body}`,
      contentType: "text/plain",
    });

    expect.soft(res.status(), `${path} gaf ${res.status()} in plaats van 401`).toBe(401);
    expect
      .soft(res.headers()["content-type"] ?? "", `${path} content-type`)
      .toContain("application/json");

    let parsed: unknown = null;
    expect.soft(() => (parsed = JSON.parse(body)), `${path} body is geen JSON: ${body.slice(0, 200)}`).not.toThrow();
    expect.soft(typeof parsed === "object" && parsed !== null, `${path} JSON is geen object`).toBe(true);

    for (const [re, what] of LEAK_PATTERNS) {
      expect.soft(body, `${path} lekt ${what}: ${body.slice(0, 300)}`).not.toMatch(re);
    }

    // Versie-informatie in headers.
    for (const h of ["server", "x-powered-by"]) {
      const v = res.headers()[h];
      if (!v) continue;
      expect.soft(v, `${path} header ${h}: "${v}" bevat een versienummer`).not.toMatch(/\d+\.\d+/);
    }
    await ctx.dispose();
  });
}

for (const path of API_PUBLIC) {
  test(`GET ${path} is bewust publiek en geeft bruikbare JSON`, async () => {
    const ctx = await pwRequest.newContext();
    const res = await ctx.get(`${APP}${path}`);
    expect(res.status()).toBe(200);
    expect(res.headers()["content-type"]).toContain("application/json");
    const body = await res.text();
    for (const [re, what] of LEAK_PATTERNS) {
      expect.soft(body, `${path} lekt ${what}`).not.toMatch(re);
    }
    await ctx.dispose();
  });
}

test("een onzinnig bearer-token wordt net zo behandeld als geen token", async () => {
  const ctx = await pwRequest.newContext();
  const variants = [
    { Authorization: "Bearer " + "a".repeat(64) },
    { Authorization: "Bearer " },
    { Authorization: "Basic YWRtaW46YWRtaW4=" },
    { Authorization: "Bearer ../../etc/passwd" },
  ];
  for (const headers of variants) {
    const res = await ctx.get(`${APP}/api/v1/vpses`, { headers });
    const body = await res.text();
    expect.soft(res.status(), `token-variant ${JSON.stringify(headers)} gaf ${res.status()}`).toBe(401);
    expect.soft(body.length, "401-body is verdacht groot").toBeLessThan(500);
    for (const [re, what] of LEAK_PATTERNS) {
      expect.soft(body, `lekt ${what} bij ${JSON.stringify(headers)}`).not.toMatch(re);
    }
  }
  await ctx.dispose();
});

test("een niet-bestaand API-pad geeft JSON, geen HTML-debugpagina", async () => {
  const ctx = await pwRequest.newContext();
  const res = await ctx.get(`${APP}/api/v1/bestaat-echt-niet`);
  const body = await res.text();
  expect.soft([401, 404], `onbekend API-pad gaf ${res.status()}`).toContain(res.status());
  expect.soft(body, "onbekend API-pad geeft een Phoenix-debugpagina").not.toContain("Phoenix");
  for (const [re, what] of LEAK_PATTERNS) {
    expect.soft(body, `onbekend API-pad lekt ${what}: ${body.slice(0, 300)}`).not.toMatch(re);
  }
  await ctx.dispose();
});

test("een ongeldige id in het pad geeft geen 500 en geen Ecto-fout", async () => {
  const ctx = await pwRequest.newContext();
  for (const id of ["abc", "0", "-1", "999999999999999999999", "%27"]) {
    const res = await ctx.get(`${APP}/api/v1/vpses/${id}`);
    const body = await res.text();
    expect.soft(res.status(), `/api/v1/vpses/${id} gaf ${res.status()}`).toBeLessThan(500);
    for (const [re, what] of LEAK_PATTERNS) {
      expect.soft(body, `/api/v1/vpses/${id} lekt ${what}`).not.toMatch(re);
    }
  }
  await ctx.dispose();
});

for (const path of API_NODE_PATHS) {
  test(`node-API ${path} wijst een aanroep zonder agent-token af`, async () => {
    const ctx = await pwRequest.newContext();
    const res = await ctx.get(`${APP}${path}`);
    const body = await res.text();
    expect.soft([401, 403], `${path} gaf ${res.status()}`).toContain(res.status());
    for (const [re, what] of LEAK_PATTERNS) {
      expect.soft(body, `${path} lekt ${what}`).not.toMatch(re);
    }
    await ctx.dispose();
  });
}

for (const path of API_ADMIN_V1) {
  test(`admin-API ${path} is van buiten niet bereikbaar`, async () => {
    const ctx = await pwRequest.newContext();
    const res = await ctx.get(`${APP}${path}`);
    // De edge stuurt /admin/v1/* niet door naar de control plane; dit hoort dus
    // op de frontend-404 te landen. Een 401 zou betekenen dat hij er wél is.
    expect.soft([401, 403, 404], `${path} gaf ${res.status()}`).toContain(res.status());
    const body = await res.text();
    expect.soft(body, `${path} lekt een Elixir-spoor`).not.toMatch(/Elixir\.|Phoenix/);
    await ctx.dispose();
  });
}

test("CORS staat niet open voor een willekeurige herkomst", async () => {
  const ctx = await pwRequest.newContext();
  const res = await ctx.get(`${APP}/api/v1/packages`, {
    headers: { Origin: "https://evil.example" },
  });
  const acao = res.headers()["access-control-allow-origin"];
  if (acao) {
    expect.soft(acao, `Access-Control-Allow-Origin is "${acao}"`).not.toBe("*");
    expect.soft(acao, `Access-Control-Allow-Origin weerspiegelt de aanvaller: "${acao}"`).not.toContain(
      "evil.example",
    );
  }
  await ctx.dispose();
});
