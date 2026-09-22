# Runbook — "ik heb betaald en ik zie geen tegoed"

Dit is het enige gesprek waarin een klant geld kwijt is en jij het moet
terugvinden. De volgorde hieronder is zo gekozen dat je nooit met de hand
bijboekt wat het systeem zelf nog gaat doen — dubbel bijschrijven is hier het
makkelijkste ongeluk.

## Hoe het hoort te gaan

1. De klant kiest een bedrag. Het control plane schrijft **eerst** een rij in
   `topup_requests` (status `pending`) en maakt **daarna** pas de betaling bij
   Mollie aan. Die volgorde is met opzet: andersom staat er bij Mollie een
   geldige betaalpagina waar wij niets van weten.
2. De klant betaalt.
3. Mollie roept onze webhook aan met het betaal-id. Die zegt niets over de
   uitkomst; hij is een seintje. Het control plane **haalt de betaling op** bij
   Mollie, over een geauthenticeerde verbinding, en kijkt wat er echt staat.
4. Staat hij op `paid` en klopt het bedrag, dan gaat het tegoed erop en wordt de
   rij `paid`.

## Waar het misgaat

Stap 3 is een verzoek van buiten naar binnen. Ligt de tunnel eruit, valt een
uitrol er precies overheen, of geeft Mollie het na zijn laatste poging op, dan
gebeurt stap 4 nooit.

**Daar hoef je meestal niets voor te doen.** De reconciler vraagt elk kwartier
zelf aan Mollie wat er is gebeurd met opwaarderingen die blijven staan, en
handelt ze af langs precies dezelfde weg. Is het minder dan een kwartier
geleden: wachten.

Schrijft de verzoening iets bij, dan staat dit in de log van het control plane:

```
mollie verzoening: betaling tr_xxx alsnog bijgeschreven -- de webhook hiervoor is nooit aangekomen
```

Zie je die regel vaker dan een enkele keer, dan is dat geen betalingsprobleem
maar een bereikbaarheidsprobleem: Mollie komt er niet doorheen. Kijk dan naar de
tunnel en naar de uitrollen van dat moment.

## Als het na een kwartier nog niet klopt

Zoek eerst de rij, met het bedrag en het tijdstip van de klant:

```sh
docker exec bf-prod-pg psql -U bunkfleet -d control_plane -c \
  "SELECT id, amount_cents, status, mollie_payment_id, inserted_at
     FROM topup_requests WHERE user_id = '<uuid>' ORDER BY inserted_at DESC LIMIT 5;"
```

Drie uitkomsten:

**De rij staat op `paid`.** Het tegoed staat erop. Laat de klant de
facturatiepagina verversen; staat het er echt niet, dan is het een fout in het
saldo en niet in de betaling — het saldo is de som van `ledger_entries`, dus
kijk daar.

**De rij staat op `pending` met een `mollie_payment_id`.** Zoek dat id op in het
Mollie-dashboard. Staat hij daar op `paid`, dan zou de verzoening hem moeten
oppakken; gebeurt dat niet, kijk of `MOLLIE_API_KEY` in `.env.prod` een
live-sleutel is. Een testsleutel schrijft met opzet niets bij, en dat staat dan
ook als fout in de log. Staat hij op `expired`, `canceled` of `failed`, dan is
er niet betaald.

**De rij staat op `pending` zonder `mollie_payment_id`.** Dan is het proces
omgevallen tussen de rij en de betaling. Er is geen betaalpagina geweest, dus er
kan ook niets binnengekomen zijn. De klant moet het opnieuw proberen.

## Met de hand bijboeken

Alleen als het Mollie-dashboard zegt `paid`, de rij niet op `paid` staat en de
verzoening hem aantoonbaar niet oppakt. Gebruik het beheerpaneel en geen SQL:
daar wordt de boeking als `admin_topup` vastgelegd, en dat is precies het
verschil tussen betaald geld en handmatig geld in het overzicht van
`Credits.saldo_naar_herkomst/0`.

Boek nooit bij zolang de rij nog `pending` is **en** de verzoening nog kan
lopen: dan komt hetzelfde bedrag er een kwartier later nog eens bij.

## Betalingen van vóór 14 september 2026

Die komen uit Mollie's testmodus. Hun betaal-ids bestaan niet in de
live-omgeving, dus de verzoening laat ze met opzet met rust — zou hij dat niet
doen, dan vraagt hij ze elk kwartier op en vindt ze elk kwartier niet. Een zo'n
rij staat nog `pending` en telt mee voor de limiet van vijf openstaande
betalingen per klant. Hij mag met de hand op `cancelled`; er beweegt geen geld.
