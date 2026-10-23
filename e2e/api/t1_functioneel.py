"""1. Werkt de ingelogde kant überhaupt? Alles hier is lezen."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 1. Functioneel, ingelogd ==")

status, me, _, _ = roep("GET", "/auth/me", token=token)
controleer("GET /auth/me geeft 200", status == 200, f"status {status}: {me}")
controleer("het is het testaccount", (me.get("user") or me).get("email") == EMAIL,
           f"kreeg {me}")
controleer("er staat geen wachtwoordhash in het antwoord",
           "password" not in json.dumps(me).lower(), f"antwoord: {me}", "HOOG")

for pad in ["/packages", "/regions", "/vpses", "/billing/wallet", "/billing/usage",
            "/auth/passkeys", "/auth/totp/setup", "/nodes"]:
    status, body, dt, _ = roep("GET", pad, token=token)
    controleer(f"GET {pad} geeft 200 ({dt*1000:.0f} ms)", status == 200,
               f"status {status}: {str(body)[:200]}")

status, wallet, _, _ = roep("GET", "/billing/wallet", token=token)
saldo = wallet.get("balance_cents")
posten = wallet.get("entries") or []
# De API geeft de laatste 25 posten. Alleen als er minder zijn, is het hele
# grootboek zichtbaar en moeten welkomstpost en som kloppen.
if len(posten) < 25:
    controleer("het welkomstkrediet staat in het grootboek",
               any(e.get("kind") == "signup_bonus" and (e.get("amount_cents") or 0) > 0
                   for e in posten),
               f"soorten: {sorted({str(e.get('kind')) for e in posten})}")
    controleer("het saldo is de som van het grootboek",
               isinstance(saldo, int) and saldo == sum(e.get("amount_cents") or 0 for e in posten),
               f"saldo {saldo}, som {sum(e.get('amount_cents') or 0 for e in posten)}")
else:
    print("  overgeslagen: 25 posten of meer, het grootboek is hier niet volledig zichtbaar.")

status, vpsen, _, _ = roep("GET", "/vpses", token=token)
lijst = vpsen.get("results", vpsen if isinstance(vpsen, list) else [])
controleer("een nieuw account heeft geen VPSen", len(lijst) == 0, f"kreeg {len(lijst)}")

status, body, _, _ = roep("GET", "/packages", token=token)
pakketten = body.get("results", [])
controleer("de catalogus heeft pakketten", len(pakketten) >= 3, f"{len(pakketten)} pakketten")
controleer("elk pakket heeft een prijs en een snelheid",
           all(p.get("price_monthly") and p.get("bandwidth_mbit") for p in pakketten),
           str(pakketten)[:300])

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
