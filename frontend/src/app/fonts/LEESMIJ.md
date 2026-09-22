# Fonts, hier en niet bij Google

`next/font/google` haalt deze bestanden op **tijdens de build**. Dat ziet eruit
als een keurige oplossing -- in productie gaat er geen enkel verzoek naar Google,
dat is nagemeten -- maar het betekent wel dat er geen build lukt zonder dat
Google bereikbaar is.

Dat viel om op 22 september 2026: VM102 lost `fonts.googleapis.com` op naar een
IPv6-adres, en in een Docker-buildcontainer werkt IPv6 niet. De uitrol klapte op
"Can't resolve '@vercel/turbopack-next/internal/font/google/font'", terwijl er
aan de fonts niets veranderd was. Een uitrol die afhangt van een derde partij is
een uitrol die op een willekeurig moment kan stilvallen, om een reden die niets
met de wijziging te maken heeft.

Daarom staan ze hier. De build heeft niets meer nodig dan deze repo.

## Waarom twee bestanden voor acht gewichten

Het zijn variabele fonts: één bestand dekt het hele gewichtsbereik. De acht
losse bestanden die Google per gewicht serveert waren byte voor byte identiek
(gecontroleerd met md5sum). 71 kB in plaats van 286.

## Alleen latin

Google serveert per schrift een eigen subset -- cyrillisch, grieks, vietnamees.
De applicatie vroeg al om `subsets: ["latin"]`, dus de rest is hier niet
opgehaald.

## Bijwerken

```sh
curl -4 -s -H 'User-Agent: Mozilla/5.0 ... Chrome/120 ...' \
  'https://fonts.googleapis.com/css2?family=Inter:wght@400..700&display=swap'
```

Zonder die User-Agent stuurt Google `ttf` in plaats van `woff2`. Pak uit het
antwoord het blok onder `/* latin */` en haal dat ene bestand op.
