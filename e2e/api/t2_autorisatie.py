"""2. Mag dit account bij de spullen van een ander?

Dit is de test die het meest telt. Een lek hier is niet "de site is traag" maar
"een klant ziet de server van een andere klant".

Alleen LEZEN en onschadelijke schrijfpogingen die hóren te falen. Er wordt niets
van iemand anders gestart, gestopt of verwijderd -- als een van deze aanroepen
tóch lukt, is dat de bevinding.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 2. Autorisatie en eigenaarschap ==")

ANDERMANS_VPS = "b734cc0f-2b46-449e-9a53-6082c5fd2f51"   # van Julian
ANDERMANS_NODE = "5e3480ca-2b8d-44fb-8e01-cb3e37a584cb"  # van Stijn
LOSSE_NODE = "b21ccf16-8cb0-44d4-9884-3923ede8690d"      # zonder eigenaar
ANDERE_USER = "404f0dc4-2ec7-4528-adb9-3969fece67c4"     # Stijn

# --- andermans VPS, in alle richtingen -------------------------------------
for methode, pad in [
    ("GET", f"/vpses/{ANDERMANS_VPS}"),
    ("GET", f"/vpses/{ANDERMANS_VPS}/backups"),
    ("POST", f"/vpses/{ANDERMANS_VPS}/start"),
    ("POST", f"/vpses/{ANDERMANS_VPS}/stop"),
    ("POST", f"/vpses/{ANDERMANS_VPS}/reboot"),
    ("POST", f"/vpses/{ANDERMANS_VPS}/console-ticket"),
    ("POST", f"/vpses/{ANDERMANS_VPS}/backups"),
    ("PATCH", f"/vpses/{ANDERMANS_VPS}"),
    ("DELETE", f"/vpses/{ANDERMANS_VPS}"),
]:
    data = {"name": "overgenomen"} if methode == "PATCH" else ({} if methode == "POST" else None)
    status, body, _, _ = roep(methode, pad, data=data, token=token)
    controleer(f"{methode} {pad.split('/')[-1] or 'vps'} van een ander wordt geweigerd",
               status in (403, 404),
               f"status {status}: {str(body)[:200]}", "KRITIEK")

# --- andermans node --------------------------------------------------------
for methode, pad, data in [
    ("PATCH", f"/nodes/{ANDERMANS_NODE}/settings", {"offer_ram_mb": 1}),
    ("POST", f"/nodes/{ANDERMANS_NODE}/owner", {"owner_email": EMAIL}),
    ("POST", f"/nodes/{ANDERMANS_NODE}/region", {"region_code": "ehv"}),
    ("PATCH", f"/nodes/{LOSSE_NODE}/settings", {"offer_ram_mb": 1}),
    ("POST", f"/nodes/{LOSSE_NODE}/owner", {"owner_email": EMAIL}),
]:
    status, body, _, _ = roep(methode, pad, data=data, token=token)
    controleer(f"{methode} {pad} wordt geweigerd", status in (403, 404),
               f"status {status}: {str(body)[:200]}", "KRITIEK")

# --- het beheerpaneel ------------------------------------------------------
for pad in ["/beheer/stats", "/beheer/users", "/beheer/vpses", "/beheer/nodes",
            "/beheer/metrics", "/beheer/regions"]:
    status, body, _, _ = roep("GET", APP + "/api/v1" + pad, token=token)
    controleer(f"GET {pad} als gewone klant wordt geweigerd", status in (401, 403, 404),
               f"status {status}: {str(body)[:200]}", "KRITIEK")

status, body, _, _ = roep("PATCH", APP + f"/api/v1/beheer/users/{ANDERE_USER}",
                          data={"role": "admin"}, token=token)
controleer("zichzelf tot beheerder maken kan niet", status in (401, 403, 404),
           f"status {status}: {str(body)[:200]}", "KRITIEK")

status, body, _, _ = roep("POST", APP + f"/api/v1/beheer/users/{ANDERE_USER}/credit",
                          data={"amount_cents": 100000}, token=token)
controleer("geld bijboeken kan niet", status in (401, 403, 404),
           f"status {status}: {str(body)[:200]}", "KRITIEK")

# --- de gedeelde-geheim-API ------------------------------------------------
for pad, data in [("/admin/v1/nodes", None), ("/admin/v1/credits", None)]:
    status, body, _, _ = roep("GET", APP + pad, token=token)
    controleer(f"GET {pad} met een klantsessie wordt geweigerd", status in (401, 403, 404),
               f"status {status}: {str(body)[:200]}", "KRITIEK")

# --- zonder enige sessie ---------------------------------------------------
for pad in ["/auth/me", "/vpses", "/billing/wallet", "/nodes"]:
    status, _, _, _ = roep("GET", pad)
    controleer(f"GET {pad} zonder token geeft 401", status == 401, f"status {status}", "KRITIEK")

# --- een verzonnen of kapot token -----------------------------------------
for slecht in ["", "onzin", "Bearer", "a" * 500, "../../etc/passwd", token[:-1] + "x"]:
    status, _, _, _ = roep("GET", "/auth/me", token=slecht)
    controleer(f"token {slecht[:14]!r} wordt geweigerd", status == 401, f"status {status}", "KRITIEK")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
