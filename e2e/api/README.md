# API-harnas (ingelogd, tegen de live omgeving)

De Playwright-suite ernaast test de uitgelogde kant met een browser. Dit harnas
test de kant daarachter: de API zoals een ingelogde klant hem gebruikt, plus de
randen waar een browser niet bij komt — rare invoer, gelijktijdige acties,
autorisatie op andermans spullen.

## Draaien

```sh
echo -n '<wachtwoord van het testaccount>' > ../.testpw   # nooit in git
cd e2e/api && python3 t1_functioneel.py
```

Er zijn geen afhankelijkheden buiten de standaardbibliotheek.

| bestand | wat het dekt |
| --- | --- |
| `t1_functioneel.py` | werkt de ingelogde kant, staat er geen hash in een antwoord |
| `t2_autorisatie.py` | andermans VPS, andermans node, het beheerpaneel, kapotte tokens |
| `t3_invoer.py` | 57 vormen van rommel; niets hoort een 5xx op te leveren |
| `t4_gelijktijdig.py` | tien bestellingen tegelijk, twintig logins, vijftig verzoeken op één sessie |
| `t5_belasting.py` | oplopende gelijktijdigheid, met de latency erbij |
| `t6_sessie.py` | uitloggen, overal uitloggen, cookievlaggen, gelijke foutmeldingen |
| `t7_protocol.py` | caching, CORS, lekkende foutmeldingen, methoden, kopinjectie |
| `t8_bestellen.py` | het geldpad: te duur, zonder vinkje, twee keer tegelijk |
| `t9_levenspad.py` | detail, hernoemen, console-ticket, tien herstarts tegelijk |
| `t10_console.py` | wie er op de webterminal mag |
| `t11_foutcontract.py` | de uitgerolde foutcodes: status én code, en er beweegt geen geld |

## Drie valkuilen die hier al ingebouwd zitten

Ze staan er met uitleg in `harnas.py`, want alle drie leverden ze een "bevinding"
op die niet bestond — en een rapport vol verzonnen problemen leest niemand meer.

1. **Een time-out is geen succes.** De eerste versie controleerde `status < 500`,
   en een mislukte verbinding heeft status 0. Het harnas vinkte zijn eigen
   time-outs af als goed.
2. **IPv6 dat niet bestaat.** Het domein heeft een AAAA-record; draait de meter
   op een machine zonder IPv6-route, dan kost elke nieuwe verbinding vijf
   seconden voordat hij terugvalt. Dat ziet eruit als een dienst die onder druk
   blijft hangen. Het harnas dwingt IPv4 af.
3. **HTTP/2 stuurt headers in kleine letters.** `dict(response.headers)` gooit de
   hoofdletterongevoeligheid weg, en dan lijkt een header te ontbreken die er
   gewoon staat.

## Wat dit harnas niet doet

Niets verwijderen van een ander account, en niets bestellen zonder dat iemand
daar expliciet om vraagt. De tests die geld raken kiezen bewust een pakket dat
duurder is dan het saldo, zodat het afschrijfpad wél wordt belopen maar er geen
VPS ontstaat.
