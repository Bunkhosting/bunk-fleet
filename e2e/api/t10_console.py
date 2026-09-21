"""10. De webterminal: wie mag er op?

Dit is het pad waarlangs iemand root krijgt op een machine. Er hoort maar één
weg naartoe te zijn: een ticket dat de eigenaar zelf heeft opgehaald, voor
precies die ene VPS, en dat daarna op is.
"""
import sys, os, base64, socket, ssl
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 10. Console-toegang ==")

_, lijst, _, _ = roep("GET", "/vpses", token=token)
vid = lijst_uit(lijst)[0]["id"]
ANDERMANS = "b734cc0f-2b46-449e-9a53-6082c5fd2f51"


def ws_handshake(pad):
    """Alleen de handshake: 101 = binnen, iets anders = geweigerd."""
    sleutel = base64.b64encode(os.urandom(16)).decode()
    ctx = ssl.create_default_context()
    rauw = socket.create_connection(("app.bunkhosting.nl", 443), timeout=10)
    s = ctx.wrap_socket(rauw, server_hostname="app.bunkhosting.nl")
    verzoek = (
        f"GET {pad} HTTP/1.1\r\nHost: app.bunkhosting.nl\r\n"
        f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {sleutel}\r\nSec-WebSocket-Version: 13\r\n"
        f"Origin: https://app.bunkhosting.nl\r\n\r\n"
    )
    s.sendall(verzoek.encode())
    antwoord = s.recv(400).decode("utf-8", "replace")
    s.close()
    return antwoord.splitlines()[0] if antwoord else "(niets)"


# --- zonder ticket ---------------------------------------------------------
regel = ws_handshake(f"/ws/console/{vid}")
controleer("zonder ticket komt er niemand binnen", "101" not in regel, regel, "KRITIEK")

# --- met onzin als ticket --------------------------------------------------
for onzin in ["x", "a" * 200, "../../etc/passwd", "null"]:
    regel = ws_handshake(f"/ws/console/{vid}?ticket={urllib.parse.quote(onzin)}")
    controleer(f"ticket {onzin[:14]!r} wordt geweigerd", "101" not in regel, regel, "KRITIEK")

# --- een echt ticket, maar voor de VPS van iemand anders -------------------
_, t, _, _ = roep("POST", f"/vpses/{vid}/console-ticket", {}, token=token)
kaartje = t["ticket"]
regel = ws_handshake(f"/ws/console/{ANDERMANS}?ticket={urllib.parse.quote(kaartje)}")
controleer("een geldig ticket opent niet de console van een ander",
           "101" not in regel, regel, "KRITIEK")

# --- hetzelfde ticket twee keer -------------------------------------------
_, t2, _, _ = roep("POST", f"/vpses/{vid}/console-ticket", {}, token=token)
k2 = t2["ticket"]
eerste = ws_handshake(f"/ws/console/{vid}?ticket={urllib.parse.quote(k2)}")
tweede = ws_handshake(f"/ws/console/{vid}?ticket={urllib.parse.quote(k2)}")
print(f"  eerste gebruik: {eerste.strip()}")
print(f"  tweede gebruik: {tweede.strip()}")
controleer("een ticket is eenmalig", "101" not in tweede, f"tweede keer: {tweede}", "KRITIEK")

# --- een ticket van een uitgelogde sessie ---------------------------------
sessie = inloggen()
_, t3, _, _ = roep("POST", f"/vpses/{vid}/console-ticket", {}, token=sessie)
roep("DELETE", "/auth/logout", token=sessie)
regel = ws_handshake(f"/ws/console/{vid}?ticket={urllib.parse.quote(t3['ticket'])}")
print(f"  ticket van een uitgelogde sessie: {regel.strip()}")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
