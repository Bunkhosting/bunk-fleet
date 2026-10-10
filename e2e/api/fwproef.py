"""Proef voor de afscherming tussen klanten op één node.

Gebruik (op VM102, waar het control plane rechtstreeks bereikbaar is):

    python3 fwproef.py bestel <regiocode>   -> drukt het id van een nieuwe test-VPS af
    python3 fwproef.py proef <vps_id> <buur_ip>
    python3 fwproef.py stil <vps_id> <seconden>  -> leeft een stille terminal nog?
    python3 fwproef.py stroom <vps_id>          -> komt veel uitvoer heelhuids aan?
    python3 fwproef.py weg <vps_id>

`proef` opent de webterminal van de test-VPS en kijkt drie dingen na: komt hij
op internet, werkt DNS, en komt hij bij de SSH-poort van een andere VPS op
dezelfde node. Vóór het aanzetten van de firewall hoort dat laatste te lukken
(daarmee is ook bewezen dat de proef rood kan worden), erna niet.
"""
import os
import sys
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import inloggen, roep, lijst_uit  # noqa: E402
from webterminal import sessie  # noqa: E402

CP_HOST = os.environ.get("BUNK_CP_HOST", "172.19.0.6")
CP_POORT = int(os.environ.get("BUNK_CP_POORT", "4000"))


def bestel(regio):
    token = inloggen()
    status, body, _, _ = roep(
        "POST",
        "/vpses",
        {
            "name": "fw-proef",
            "vcpu": 1,
            "ram_mb": 1024,
            "disk_gb": 20,
            "region_code": regio,
            "immediate_delivery_consent": True,
        },
        token=token,
    )
    if status not in (200, 201):
        sys.exit(f"bestellen mislukte: {status} {body}")
    vid = body["vps"]["id"]
    for _ in range(60):
        _, b, _, _ = roep("GET", f"/vpses/{vid}", token=token)
        st = b.get("vps", {}).get("status")
        if st == "active":
            print(vid, b["vps"].get("ip_address"))
            return
        if st in ("failed", "error"):
            sys.exit(f"uitrol mislukt: {b}")
        time.sleep(10)
    sys.exit("niet actief binnen tien minuten")


def proef(vid, buur):
    token = inloggen()
    status, body, _, _ = roep("POST", f"/vpses/{vid}/console-ticket", {}, token=token)
    if status != 200:
        sys.exit(f"geen ticket: {status} {body}")
    pad = f"/ws/console/{vid}/?ticket={urllib.parse.quote(body['ticket'])}"
    opdrachten = [
        "ping -c2 -W2 1.1.1.1 >/dev/null 2>&1 && echo UIT=NET_OK || echo UIT=NET_KAPOT",
        "getent hosts deb.debian.org >/dev/null && echo UIT=DNS_OK || echo UIT=DNS_KAPOT",
        f"timeout 4 bash -c '</dev/tcp/{buur}/22' 2>/dev/null && echo UIT=BUUR_OPEN || echo UIT=BUUR_DICHT",
    ]
    uit = sessie(CP_HOST, CP_POORT, pad, opdrachten, per_opdracht=10.0)
    regels = sorted({r.strip() for r in uit.replace("\r", "\n").split("\n") if r.strip().startswith("UIT=")})
    print(" ".join(regels) or "geen uitkomst; ruwe uitvoer:\n" + uit[-400:])


def stil(vid, seconden):
    """Opent een sessie, doet `seconden` niets, en kijkt of hij nog leeft."""
    token = inloggen()
    status, body, _, _ = roep("POST", f"/vpses/{vid}/console-ticket", {}, token=token)
    if status != 200:
        sys.exit(f"geen ticket: {status} {body}")
    pad = f"/ws/console/{vid}/?ticket={urllib.parse.quote(body['ticket'])}"
    uit = sessie(CP_HOST, CP_POORT, pad, ["echo UIT=LEEFT"], eerste_wacht=float(seconden), per_opdracht=8.0)
    print("UIT=LEEFT" if "UIT=LEEFT" in uit else "DICHT na stilte; staart: " + uit[-200:].replace("\n", " "))


def stroom(vid):
    """Stuurt ~2 MB uitvoer door de terminal en kijkt of alles aankomt."""
    token = inloggen()
    status, body, _, _ = roep("POST", f"/vpses/{vid}/console-ticket", {}, token=token)
    if status != 200:
        sys.exit(f"geen ticket: {status} {body}")
    pad = f"/ws/console/{vid}/?ticket={urllib.parse.quote(body['ticket'])}"
    uit = sessie(CP_HOST, CP_POORT, pad, ["seq 1 300000; echo UIT=KLAAR"], per_opdracht=40.0)
    print(f"{len(uit)} tekens ontvangen;",
          "laatste getal aangekomen" if "\n300000" in uit.replace("\r", "") else "laatste getal NIET aangekomen",
          "UIT=KLAAR" if "UIT=KLAAR" in uit else "geen UIT=KLAAR")


def weg(vid):
    token = inloggen()
    status, body, _, _ = roep("DELETE", f"/vpses/{vid}", token=token)
    print("verwijderen:", status)
    for _ in range(30):
        _, lijst, _, _ = roep("GET", "/vpses", token=token)
        if not any(v["id"] == vid for v in lijst_uit(lijst)):
            print("weg")
            return
        time.sleep(10)
    print("nog niet weg na vijf minuten")


if __name__ == "__main__":
    {"bestel": lambda: bestel(sys.argv[2]), "proef": lambda: proef(sys.argv[2], sys.argv[3]),
     "stil": lambda: stil(sys.argv[2], sys.argv[3]),
     "stroom": lambda: stroom(sys.argv[2]),
     "weg": lambda: weg(sys.argv[2])}[sys.argv[1]]()
