#!/usr/bin/env python3
"""Kijkt of elke foutcode die het control plane kan sturen een zin heeft.

Waarom dit buiten beide testsuites staat: het is de enige controle die over de
grens tussen Elixir en TypeScript heen kijkt. `mix test` ziet `frontend/` niet
(de testcontainer mount alleen control_plane/) en de e2e-suite draait tegen een
live omgeving en kent de tabel niet. In CI staat de hele repo er wel, dus daar
kan het -- en het kost een seconde.

Wat het vangt: een foutcode die een bezoeker terug kan krijgen en waar niemand
een zin bij heeft geschreven. Hij kijkt daarvoor niet alleen in de foutentabel
maar ook naar de codes die controllers rechtstreeks versturen -- het gaat om wat
er bij iemand aankomt, niet om langs welke weg. De bezoeker krijgt anders de
algemene terugvalzin van de pagina, en dat is geen storing maar wel precies de
stille verschraling die de tabel moest wegnemen.

Uitzonderingen staan hieronder met een reden erbij. Een lege lijst is beter dan
een lange: hoe meer er in staat, hoe minder dit meet.
"""

import re
import sys
from pathlib import Path

WORTEL = Path(__file__).resolve().parent.parent
WEB = WORTEL / "control_plane/lib/control_plane_web"
FOUTEN = WEB / "fouten.ex"
API = WORTEL / "frontend/src/lib/api.ts"

# Controllers die geen browser bedienen. Hun antwoorden gaan naar de agent op
# een node of naar Mollie, en daar leest niemand een Nederlandse zin. Een code
# hieruit in ERROR_MESSAGES zetten zou de lijst vullen met zinnen die nooit op
# een scherm komen -- en dan zegt "allemaal vertaald" niets meer.
MACHINES = {
    "heartbeat_controller.ex",
    "enroll_controller.ex",
    "command_controller.ex",
    "port_forward_controller.ex",
    "worker_install_controller.ex",
    "mollie_controller.ex",
}

# Codes die met opzet geen eigen zin hebben. De terugvalzin van de pagina is
# daar beter, omdat de code niets zegt wat de bezoeker kan gebruiken.
GEEN_ZIN_NODIG = {
    # Een sleutel die de frontend zelf aanmaakt. Als die niet deugt is dat een
    # fout in onze code, geen keuze van de klant; "probeer het opnieuw" van de
    # pagina zelf is het enige zinnige antwoord.
    "invalid_idempotency_key",
    # Deze twee zeggen alleen "het lukte niet", en dat zegt de knop waar je net
    # op drukte al met meer context: "opslaan is niet gelukt" op het scherm
    # waar je aan het opslaan was. Een eigen zin zou minder zeggen, niet meer.
    "update_failed",
    "delete_failed",
}


# Twee manieren waarop een controller een code stuurt zonder de tabel: via de
# eigen `error/3`-helper, of rechtstreeks met een json-antwoord. Allebei tellen;
# het gaat erom wat er bij een bezoeker aankomt, niet langs welke weg.
LOSSE_CODE = re.compile(
    r'error\(conn,\s*:[a-z_]+,\s*"([a-z_0-9]+)"\)' r'|json\(%\{error:\s*"([a-z_0-9]+)"\}\)'
)


def codes_uit_backend() -> set[str]:
    """Elke foutcode die een browser van ons terug kan krijgen."""
    tekst = FOUTEN.read_text(encoding="utf-8")
    codes = set(re.findall(r'\{:[a-z_]+,\s*"([a-z_0-9]+)"\}', tekst))

    for pad in (WEB / "controllers").rglob("*.ex"):
        if pad.name in MACHINES:
            continue
        for m in LOSSE_CODE.finditer(pad.read_text(encoding="utf-8")):
            codes.add(m.group(1) or m.group(2))

    return codes


def codes_uit_frontend() -> set[str]:
    tekst = API.read_text(encoding="utf-8")
    begin = tekst.index("const ERROR_MESSAGES")
    blok = tekst[begin:]
    blok = blok[: blok.index("\n};")]
    return set(re.findall(r'^\s*"?([a-z_0-9]+)"?:', blok, re.M))


def main() -> int:
    backend = codes_uit_backend()
    frontend = codes_uit_frontend()

    if not backend or not frontend:
        print("foutcodes: een van beide lijsten is leeg -- is een bestand verplaatst?")
        return 2

    zonder_zin = sorted(backend - frontend - GEEN_ZIN_NODIG)
    if zonder_zin:
        print("Deze foutcodes kan het control plane sturen, maar de frontend")
        print("heeft er geen zin voor. Zet ze in ERROR_MESSAGES in")
        print("frontend/src/lib/api.ts, of in GEEN_ZIN_NODIG hieronder met een")
        print("reden waarom de terugvalzin beter is:")
        for c in zonder_zin:
            print(f"  - {c}")
        return 1

    print(f"foutcodes: {len(backend)} codes, allemaal vertaald")
    return 0


if __name__ == "__main__":
    sys.exit(main())
