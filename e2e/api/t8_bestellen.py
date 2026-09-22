"""8. Het bestelpad, met echt geld en echte capaciteit.

Eén Starter. Voor, tijdens en na wordt het saldo geteld, want "de API zei ja" en
"er is precies één keer afgeschreven" zijn twee verschillende beweringen.

## Wat hier eerder misging

De eerste versie stuurde `{"package_id": 1, "os": "ubuntu-22.04", "label": ...}`
-- de vorm die het BESTELSCHERM kent. De API kent die vorm niet: die wil
`name`, `vcpu`, `ram_mb` en `disk_gb`, want het scherm rekent het pakket zelf om
naar specificaties. Elke bestelling strandde dus op de validatie met een 422.

Daarmee was elke bewering in dit bestand waar om de verkeerde reden. "Hooguit
één VPS" klopt triviaal als er nul worden aangemaakt, en "afgeschreven in (0,
399)" wordt gehaald door een nul. De test die het duurste pad in het product
bewaakt, raakte dat pad nooit aan.

Daarom staat er nu overal eerst een controle dat het verzoek is AANGENOMEN. Een
test die niet kan zien of hij het pad haalde dat hij denkt te testen, meet niets.
"""
import sys, os, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 8. Bestellen ==")

# De Starter, zoals de API hem wil zien. Niet het pakketnummer: dat rekent het
# bestelscherm om, en hier praten we rechtstreeks met de API.
STARTER = {"name": "harnas-bestelpad", "vcpu": 1, "ram_mb": 1024, "disk_gb": 20}


def saldo():
    _, w, _, _ = roep("GET", "/billing/wallet", token=token)
    return w.get("balance_cents")


voor = saldo()
print(f"  saldo vooraf: €{voor/100:.2f}")

# --- 1. Bestellen zonder het vinkje voor directe levering -----------------
#
# Dit kost niets en mag dus altijd draaien. De code die het weigert is precies
# de code die een bestelling zou aannemen, dus dit is ook de controle dat de
# vorm van het verzoek klopt: kwam er iets anders terug dan
# `no_delivery_consent`, dan strandde het eerder en meet de rest niets.
status, body, _, _ = roep("POST", "/vpses", dict(STARTER), token=token)
code = body.get("error") if isinstance(body, dict) else None
controleer("zonder toestemming voor directe levering wordt er niet besteld",
           status == 422 and code == "no_delivery_consent",
           f"status {status}: {str(body)[:160]}", "HOOG")
controleer("en er is niets afgeschreven", saldo() == voor, f"saldo {saldo()} vs {voor}", "KRITIEK")

if not mag_bestellen("het bestelpad hieronder"):
    print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
    sys.exit(0)

# --- 2. Twee identieke bestellingen tegelijk, met dezelfde sleutel ---------
sleutel = "harnas-" + str(int(time.time()))
bestelling = dict(STARTER, immediate_delivery_consent=True, name="harnas-dubbel")

with cf.ThreadPoolExecutor(max_workers=2) as pool:
    res = [f.result() for f in [pool.submit(
        roep, "POST", "/vpses", bestelling, token, {"Idempotency-Key": sleutel})
        for _ in range(2)]]

statussen = [s for s, _, _, _ in res]
lichamen = [b for _, b, _, _ in res]
print(f"  twee gelijktijdige bestellingen met dezelfde sleutel: {statussen}")

# Eerst: is er überhaupt iets aangenomen? Zonder deze regel is alles hieronder
# waar zodra beide verzoeken worden geweigerd, en dat is precies hoe dit
# bestand maandenlang groen stond zonder iets te meten.
aangenomen = [s for s in statussen if s in (200, 201)]
controleer("ten minste één van de twee bestellingen is aangenomen",
           len(aangenomen) >= 1,
           f"statussen {statussen}, lichamen {str(lichamen)[:200]}", "KRITIEK")

gelukt = [b for s, b in zip(statussen, lichamen) if s in (200, 201)]
ids = {(b.get("vps") or b).get("id") for b in gelukt if isinstance(b, dict)}
controleer("dezelfde sleutel levert precies één VPS op", len(ids) == 1,
           f"ids: {ids}", "KRITIEK")

na = saldo()
afgeschreven = voor - na
print(f"  saldo na: €{na/100:.2f} (afgeschreven: €{afgeschreven/100:.2f})")
controleer("er is precies één keer €3,99 afgeschreven", afgeschreven == 399,
           f"er ging €{afgeschreven/100:.2f} af", "KRITIEK")

json.dump({"ids": list(ids), "voor": voor, "na": na, "statussen": statussen},
          open(os.path.join(os.path.dirname(HIER), "bestelling.json"), "w"))
print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
