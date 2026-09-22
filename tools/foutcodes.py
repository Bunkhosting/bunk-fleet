#!/usr/bin/env python3
"""Kijkt of elke foutcode die het control plane kan sturen een zin heeft.

Waarom dit buiten beide testsuites staat: het is de enige controle die over de
grens tussen Elixir en TypeScript heen kijkt. `mix test` ziet `frontend/` niet
(de testcontainer mount alleen control_plane/) en de e2e-suite draait tegen een
live omgeving en kent de tabel niet. In CI staat de hele repo er wel, dus daar
kan het -- en het kost een seconde.

Wat het vangt: een nieuwe reden in `Fouten` waar niemand een zin bij schrijft.
De klant krijgt dan de algemene terugvalzin van de pagina, en dat is geen storing
maar wel precies de stille verschraling die deze tabel moest wegnemen.

Uitzonderingen staan hieronder met een reden erbij. Een lege lijst is beter dan
een lange: hoe meer er in staat, hoe minder dit meet.
"""

import re
import sys
from pathlib import Path

WORTEL = Path(__file__).resolve().parent.parent
FOUTEN = WORTEL / "control_plane/lib/control_plane_web/fouten.ex"
API = WORTEL / "frontend/src/lib/api.ts"

# Codes die met opzet geen eigen zin hebben. De terugvalzin van de pagina is
# daar beter, omdat de code niets zegt wat de bezoeker kan gebruiken.
GEEN_ZIN_NODIG = {
    # Een sleutel die de frontend zelf aanmaakt. Als die niet deugt is dat een
    # fout in onze code, geen keuze van de klant; "probeer het opnieuw" van de
    # pagina zelf is het enige zinnige antwoord.
    "invalid_idempotency_key",
}


def codes_uit_fouten() -> set[str]:
    tekst = FOUTEN.read_text(encoding="utf-8")
    return set(re.findall(r'\{:[a-z_]+,\s*"([a-z_0-9]+)"\}', tekst))


def codes_uit_frontend() -> set[str]:
    tekst = API.read_text(encoding="utf-8")
    begin = tekst.index("const ERROR_MESSAGES")
    blok = tekst[begin:]
    blok = blok[: blok.index("\n};")]
    return set(re.findall(r'^\s*"?([a-z_0-9]+)"?:', blok, re.M))


def main() -> int:
    backend = codes_uit_fouten()
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
