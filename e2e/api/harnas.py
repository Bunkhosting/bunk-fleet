"""Testharnas tegen de live omgeving van Bunk.

Grenzen die hier in code staan en niet alleen in een belofte:
  * alleen het testaccount logt in; er wordt nooit met een ander account gewerkt;
  * geen enkele aanroep die geld uitgeeft of iets aanmaakt dat blijft staan,
    tenzij expliciet met MAG_BESTELLEN=1 aangezet;
  * bij een 5xx of een time-out stopt de betreffende reeks in plaats van door te
    beuken -- een test die een storing verergert is geen test maar een storing.
"""
import json, os, ssl, sys, time, threading, urllib.request, urllib.error, urllib.parse
from collections import Counter

# IPv4 afdwingen, en dat is geen detail.
#
# app.bunkhosting.nl heeft een AAAA-record (Cloudflare), deze container heeft
# geen IPv6-route. Elke nieuwe verbinding probeerde daardoor eerst IPv6, liep
# dood, en viel na vijf seconden terug op IPv4. In een belastingmeting ziet dat
# eruit als een dienst die onder druk blijft hangen -- compleet met tijden die
# keurige veelvouden van vijf seconden zijn. Het scheelde weinig of dat was hier
# gerapporteerd als een ernstig beschikbaarheidsprobleem van Bunk, terwijl het
# het netwerk van de meter was.
#
# Een echte bezoeker heeft hier veel minder last van: browsers doen Happy
# Eyeballs (RFC 8305) en vallen binnen ~250 ms terug. curl en urllib niet.
import socket as _socket

_echte_getaddrinfo = _socket.getaddrinfo


def _alleen_ipv4(host, port, family=0, type=0, proto=0, flags=0):
    return _echte_getaddrinfo(host, port, _socket.AF_INET, type, proto, flags)


_socket.getaddrinfo = _alleen_ipv4

APP = "https://app.bunkhosting.nl"
API = APP + "/api/v1"
HIER = os.path.dirname(os.path.abspath(__file__))
PW = open(os.path.join(os.path.dirname(HIER), ".testpw")).read().strip()
EMAIL = "test@bunkhosting.nl"

bevindingen = []
tellers = Counter()


def roep(methode, pad, data=None, token=None, headers=None, timeout=15):
    url = pad if pad.startswith("http") else API + pad
    body = None
    h = {"Accept": "application/json", "User-Agent": "bunk-testharnas/1.0"}
    if data is not None:
        body = json.dumps(data).encode()
        h["Content-Type"] = "application/json"
    if token:
        h["Authorization"] = "Bearer " + token
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=body, headers=h, method=methode)
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            ruw = r.read()
            return r.status, ontleed(ruw), time.time() - t0, Headers(r.headers.items())
    except urllib.error.HTTPError as e:
        ruw = e.read()
        return e.code, ontleed(ruw), time.time() - t0, Headers(e.headers.items())
    except Exception as e:
        return 0, {"fout": repr(e)}, time.time() - t0, Headers([])


class Headers(dict):
    """Headers waarbij hoofdletters niet uitmaken.

    HTTP/1.1 stuurt `X-Frame-Options`, HTTP/2 stuurt `x-frame-options`, en
    `dict(response.headers)` gooit de ongevoeligheid van het origineel weg.
    Een test die daarna op de ene schrijfwijze zoekt, meldt een ontbrekende
    header die er gewoon staat -- precies wat hier gebeurde, en het scheelde
    weinig of er was een reparatie geschreven voor een probleem dat niet bestond.
    """

    def __init__(self, paren):
        super().__init__((k.lower(), v) for k, v in paren)

    def get(self, key, standaard=None):
        return super().get(key.lower(), standaard)

    def __contains__(self, key):
        return super().__contains__(key.lower())


def ontleed(ruw):
    try:
        return json.loads(ruw)
    except Exception:
        return {"_ruw": ruw[:400].decode("utf-8", "replace")}


def geslaagd(status):
    """Wat telt als een antwoord.

    Status 0 is in dit harnas een uitzondering aan de clientkant: een time-out of
    een verbinding die niet tot stand kwam. Dat is voor een bezoeker ERGER dan
    een 500 -- die krijgt tenminste iets -- dus een test die alleen op `< 500`
    let, rekent zijn eigen time-outs als succes. Dat deed dit harnas, en het
    verborg precies de bevinding waar de meting om begonnen was.
    """
    return 0 < status < 500


def bevinding(ernst, titel, detail):
    bevindingen.append((ernst, titel, detail))
    print(f"  [{ernst}] {titel}\n      {detail}")


def controleer(naam, voorwaarde, detail="", ernst="MIDDEL"):
    tellers["totaal"] += 1
    if voorwaarde:
        tellers["goed"] += 1
        print(f"  ok   {naam}")
    else:
        tellers["fout"] += 1
        bevinding(ernst, naam, detail)
    return voorwaarde


def lijst_uit(body):
    """De lijst uit een antwoord halen, hoe de sleutel ook heet.

    /vpses geeft {"vpses": [...]}, /packages geeft {"results": [...]} en
    /regions geeft {"regions": [...]}. Een test die één vorm aanneemt meldt een
    lege lijst waar er een volle staat -- en dat leest als een ernstige bug
    terwijl het een sleutelnaam is.
    """
    if isinstance(body, list):
        return body
    if not isinstance(body, dict):
        return []
    for sleutel in ("results", "vpses", "regions", "nodes", "backups", "entries", "data"):
        if isinstance(body.get(sleutel), list):
            return body[sleutel]
    for waarde in body.values():
        if isinstance(waarde, list):
            return waarde
    return []


def mag_bestellen(wat="deze reeks"):
    """Stopt een test die geld uitgeeft of iets achterlaat, tenzij het mag.

    De regel stond in de moduledoc van dit bestand en werd door niets
    afgedwongen -- een belofte in commentaar is geen grens. Wie een van deze
    tests per ongeluk aanzet, koopt een VPS van iemands echte tegoed.

    Zet MAG_BESTELLEN=1 in de omgeving om hem te draaien.
    """
    if os.environ.get("MAG_BESTELLEN") == "1":
        return True
    print(f"  overgeslagen: {wat} geeft geld uit. Zet MAG_BESTELLEN=1 als dat mag.")
    return False


def inloggen():
    status, body, _, _ = roep("POST", "/auth/login", {"email": EMAIL, "password": PW})
    if status != 200:
        print(f"inloggen mislukt ({status}): {body}")
        sys.exit(1)
    return body.get("token")
