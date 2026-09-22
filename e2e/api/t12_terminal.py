"""12. De webterminal, de enige ingang tot een VPS.

Geen SSH van buiten, geen poortdoorverwijzing: wie bij zijn machine wil, doet
dat hier. En juist dit stuk had geen enkele geautomatiseerde dekking -- de
browsersuite komt niet achter het inlogscherm met een xterm, en dit harnas sprak
alleen HTTP. Zo bleef een storing van één op de zes sessies onopgemerkt: de
SSH-grens onder de relay stond korter dan de koppelgrens erboven, en een
handshake die door de tunnel net iets langer deed werd aan de klant gemeld als
"je VPS neemt geen SSH aan".

## Waar dit draait

Rechtstreeks tegen de control-plane-container, niet via app.bunkhosting.nl: een
handgebouwde TLS-handshake wordt door Cloudflare geweigerd met een 403. Zet
BUNK_CP_HOST en BUNK_CP_POORT als ze ergens anders staan. Draait dit op een
machine zonder toegang tot dat netwerk, dan slaat hij zichzelf over in plaats
van rood te worden over iets wat hij niet kan meten.

## Geen herkansingen

Een flake is hier informatie. Vijf sessies achter elkaar op een VPS die draait,
horen vijf keer een shell te geven; lukt dat niet, dan is dat precies het soort
storing waarvoor dit bestand is geschreven.
"""
import os
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *  # noqa: F403
from webterminal import sessie

CP_HOST = os.environ.get("BUNK_CP_HOST", "172.19.0.3")
CP_POORT = int(os.environ.get("BUNK_CP_POORT", "4000"))
POGINGEN = 5

token = inloggen()
print("== 12. De webterminal ==")

# Bereikbaar? Zo niet: overslaan. Rood worden omdat de meter ergens anders staat
# dan de dienst, is precies het soort bevinding dat niemand meer leest.
try:
    socket.create_connection((CP_HOST, CP_POORT), timeout=3).close()
except OSError as e:
    print(f"  overgeslagen: {CP_HOST}:{CP_POORT} is hiervandaan niet bereikbaar ({e})")
    print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
    sys.exit(0)

_, lijst, _, _ = roep("GET", "/vpses", token=token)
draaiend = [v for v in lijst_uit(lijst) if v.get("status") == "active"]

if not draaiend:
    # Zonder VPS valt er niets te openen. Dat is geen fout van het product.
    print("  overgeslagen: het testaccount heeft geen draaiende VPS")
    print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
    sys.exit(0)

vps = draaiend[0]
print(f"  tegen VPS {vps['id'][:8]} ({vps.get('region')})")

shells = 0
meldingen = []

for _ in range(POGINGEN):
    status, body, _, _ = roep("POST", f"/vpses/{vps['id']}/console-ticket", {}, token=token)
    if status != 200 or not isinstance(body, dict) or not body.get("ticket"):
        meldingen.append(f"geen ticket: status {status} {str(body)[:80]}")
        continue

    pad = f"/ws/console/{vps['id']}/?ticket={urllib.parse.quote(body['ticket'])}"
    try:
        uit = sessie(CP_HOST, CP_POORT, pad)
    except Exception as e:  # handshake mislukt: dat is de terminal zelf
        meldingen.append(f"handshake: {e!r}")
        continue

    if "Welcome to" in uit or "$ " in uit:
        shells += 1
    else:
        meldingen.append(uit.strip().splitlines()[-1][:110] if uit.strip() else "(stil)")

print(f"  {shells} van {POGINGEN} sessies gaven een shell")

controleer(
    f"de webterminal opent {POGINGEN} van de {POGINGEN} keer",
    shells == POGINGEN,
    "; ".join(meldingen[:3]) or "geen melding",
    "HOOG",
)

# Een mislukte sessie hoort te ZEGGEN wat er mis is, niet stil te vallen. De
# klant die niets leest, belt.
if meldingen:
    controleer(
        "en een mislukte sessie legt uit waarom",
        all(m != "(stil)" for m in meldingen),
        f"{meldingen.count('(stil)')} sessie(s) vielen zonder uitleg dicht",
        "MIDDEL",
    )

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
