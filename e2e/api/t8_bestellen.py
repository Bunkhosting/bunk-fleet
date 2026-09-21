"""8. Het bestelpad, met echt geld en echte capaciteit.

Eén Starter. Voor, tijdens en na wordt het saldo geteld, want "de API zei ja" en
"er is precies één keer afgeschreven" zijn twee verschillende beweringen.
"""
import sys, os, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 8. Bestellen ==")


def saldo():
    _, w, _, _ = roep("GET", "/billing/wallet", token=token)
    return w.get("balance_cents")


def regels():
    _, u, _, _ = roep("GET", "/billing/usage", token=token)
    return u


voor = saldo()
print(f"  saldo vooraf: €{voor/100:.2f}")

# --- 1. Bestellen zonder het vinkje voor directe levering -----------------
status, body, _, _ = roep("POST", "/vpses", {
    "package_id": 1, "os": "ubuntu-22.04", "label": "harnas-zonder-vinkje"}, token=token)
controleer("zonder toestemming voor directe levering wordt er niet besteld",
           status >= 400, f"status {status}: {str(body)[:160]}", "HOOG")
controleer("en er is niets afgeschreven", saldo() == voor, f"saldo {saldo()} vs {voor}", "KRITIEK")

# --- 2. Twee identieke bestellingen tegelijk, met dezelfde idempotentiesleutel
sleutel = "harnas-" + str(int(time.time()))
with cf.ThreadPoolExecutor(max_workers=2) as pool:
    res = [f.result() for f in [pool.submit(
        roep, "POST", "/vpses",
        {"package_id": 1, "os": "ubuntu-22.04", "label": "harnas-dubbel",
         "immediate_delivery_consent": True},
        token, {"Idempotency-Key": sleutel}) for _ in range(2)]]

statussen = [s for s, _, _, _ in res]
lichamen = [b for _, b, _, _ in res]
print(f"  twee gelijktijdige bestellingen met dezelfde sleutel: {statussen}")

gelukt = [b for s, b in zip(statussen, lichamen) if s in (200, 201)]
ids = {(b.get("vps") or b).get("id") for b in gelukt if isinstance(b, dict)}
controleer("dezelfde sleutel levert hooguit één VPS op", len(ids) <= 1,
           f"ids: {ids}", "KRITIEK")

na = saldo()
afgeschreven = voor - na
print(f"  saldo na: €{na/100:.2f} (afgeschreven: €{afgeschreven/100:.2f})")
controleer("er is precies één keer €3,99 afgeschreven", afgeschreven in (0, 399),
           f"er ging €{afgeschreven/100:.2f} af", "KRITIEK")

json.dump({"ids": list(ids), "voor": voor, "na": na, "statussen": statussen},
          open(os.path.join(os.path.dirname(HIER), "bestelling.json"), "w"))
print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
