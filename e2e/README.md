# bunk-fleet e2e-suite (productie, read-only)

Playwright-suite die tegen de **live** omgeving draait: `https://app.bunkhosting.nl`
(klantpaneel + API) en `https://bunkhosting.nl` (marketingsite).

## Wat deze suite bewust NIET doet

Er is geen testaccount en registratie zit achter Cloudflare Turnstile. De suite
is daarom volledig read-only:

- geen registratie, geen wachtwoord-reset (dat stuurt echte mail), geen Mollie;
- geen POST/PATCH/DELETE op een endpoint dat iets kan muteren;
- geen aanraking van een bestaande VPS, node, regio of gebruiker;
- op `/register` wordt alleen gecontroleerd dát de verzendknop uitstaat zolang
  er geen Turnstile-token is — daar zit de veiligheidsklep.

## Draaien

```bash
cd e2e
npm install
docker run --rm --cpus=1 -v "$PWD":/work -w /work -e HOME=/work \
  mcr.microsoft.com/playwright:v1.50.0-noble npx playwright test
```

Tegen een andere omgeving: `BUNK_APP_URL` en `BUNK_WWW_URL`.

## Wat groen en rood betekenen hier

Twee markeringen houden de suite eerlijk, en allebei staan ze in
`lib/openstaand.ts`:

- **`openstaand(reden)`** -- de test faalt vandaag om iets wat bekend is en
  buiten deze repo gerepareerd moet worden (de marketingsite draait uit een
  eigen repo op LXC 104). De test draait wél: zodra het is opgelost wordt de
  run rood met "expected to fail but passed", en dan haalt iemand de regel weg.
  Overslaan zou betekenen dat niemand ooit merkt dat het klaar is.
- **`alleenEchteBrowser(wat)`** -- Cloudflare Turnstile bedient een headless
  Chromium niet. Geen widget, dus geen token, dus blijft de verzendknop uit en
  is hij ook niet focusbaar. Dat is vermoedelijk het product dat doet wat het
  moet doen; zolang niemand dat met een gewone browser heeft bevestigd valt er
  vanaf hier niets over te beweren. Draai met `BUNK_ECHTE_BROWSER=1` als je wél
  een echte browser hebt.

Wat de suite dus NIET doet: rood staan op een ontwerpkeuze. De 44px-vuistregel
voor aanraakdoelen is een advies en komt als annotatie in het rapport; de
24px-grens van WCAG 2.5.8 is een fout en laat de test vallen.

**Let op — draai dit liever niet op VM102 zelf.** Die machine heeft 2 vCPU en
4 GB en draait ook de control plane, de frontend, Postgres en de edge. Tijdens
een run met vier parallelle Chromiums liep het load-gemiddelde naar 30+ en
verdween de qemu-guest-agent van VM102 uit de lucht: de site bleef in 0,1 s
antwoorden, maar `qm guest exec` deed niets meer. De config staat daarom op
**één worker en `fullyParallel: false`**, en er draait een gezondheidswacht
(`lib/fixtures.ts`) die vóór elk testblok kijkt of `/healthz` nog binnen een
seconde antwoordt en anders pauzeert tot het herstelt. Wat hij onderweg ziet
wegzakken komt in `tests/zz-capaciteit.spec.ts` als bevinding terug.

Zet `BUNK_WORKERS` hoger alleen op een machine die niets anders te doen heeft.
De suite praat alleen over https met de publieke domeinen en hoeft dus nergens
binnen te staan.

Alleen Chromium: beide projecten gebruiken het Chrome-profiel uit het image.
Er wordt geen browser gedownload — die zitten al in het image, en dat is precies
waarom de versie gepind moet blijven.

De Playwright-versie in `package.json` is **vastgepind op 1.50.0**, gelijk aan
de tag van het image. Met een caret (`^1.50.0`) installeert npm een nieuwere
client en faalt elke browsertest met "Executable doesn't exist" — de browsers
zitten in het image, niet in `node_modules`.

Rapport: `playwright-report/index.html`, machineleesbaar `results.json`,
screenshots en bijlagen onder `test-results/`.

Andere omgeving: `BUNK_APP_URL` / `BUNK_WWW_URL`.

## Indeling

| Bestand | Dekt |
| --- | --- |
| `tests/public-pages.spec.ts` | beide domeinen laden, console-errors, gebroken requests, mixed content |
| `tests/security-headers.spec.ts` | CSP, HSTS, XFO/frame-ancestors, referrer policy, cookievlaggen, http→https |
| `tests/auth-redirects.spec.ts` | `/dashboard/**` redirect naar login, geen inhoud-flits, open redirect |
| `tests/forms.spec.ts` | clientvalidatie login/registratie/wachtwoord-vergeten |
| `tests/api-unauth.spec.ts` | 401-gedrag, JSON-vorm, geen stacktrace/versielek |
| `tests/mobile.spec.ts` | 390px: horizontale scroll, aanraakdoelen |
| `tests/a11y.spec.ts` | axe-core WCAG 2.1 AA, labels, focusvolgorde, alt |
| `tests/passkey.spec.ts` | passkey-ceremonie met Chromium's virtuele authenticator: toevoegen, inloggen, verwijderen. Muteert alleen het testaccount (één passkey erbij en weer eraf, ook bij falen); slaat over zonder `e2e/.testpw` |
| `tests/wellknown-404.spec.ts` | healthz, robots, sitemap, security.txt, 404 |
| `tests/zz-capaciteit.spec.ts` | wat de suite zélf met de dienst deed (loopt als laatste) |

`expect.soft` is de regel, niet de uitzondering: een run die faalt hoort alle
gaten te laten zien, niet alleen de eerste.
