"""4. Dezelfde actie tien keer tegelijk.

Hier zitten de fouten die je met één verzoek nooit ziet: twee afschrijvingen op
hetzelfde saldo, twee sessies waar er een hoort, een teller die een tik mist.

VEILIG GEKOZEN: er wordt besteld op een pakket dat DUURDER is dan het saldo.
Elke poging hoort af te ketsen op "te weinig tegoed" -- dus er ontstaat geen VPS
en er wordt geen capaciteit aangeraakt -- maar het afschrijfpad mét zijn slot
wordt wel tien keer tegelijk belopen. Als daar een gat zit, zakt het saldo.
"""
import sys, os, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 4. Gelijktijdigheid ==")


def saldo():
    _, w, _, _ = roep("GET", "/billing/wallet", token=token)
    return w.get("balance_cents")


def parallel(n, fn):
    with cf.ThreadPoolExecutor(max_workers=n) as pool:
        return [f.result() for f in [pool.submit(fn, i) for i in range(n)]]


# --- 1. Tien bestellingen tegelijk die alle tien te duur zijn --------------
_, pakketten, _, _ = roep("GET", "/packages", token=token)
duur = max(pakketten["results"], key=lambda p: float(p["price_monthly"]))
print(f"  (gekozen pakket: {duur['name']} à €{duur['price_monthly']}, saldo €{saldo()/100:.2f})")

voor = saldo()
uitkomsten = parallel(10, lambda i: roep("POST", "/vpses", {
    "package_id": duur["id"], "os": "ubuntu-22.04",
    "label": f"harnas-{i}", "immediate_delivery_consent": True}, token=token))
na = saldo()

statussen = Counter(s for s, _, _, _ in uitkomsten)
print(f"  statussen: {dict(statussen)}")
controleer("geen enkele te dure bestelling lukte", 201 not in statussen and 200 not in statussen,
           f"statussen {dict(statussen)}", "KRITIEK")
controleer("geen 5xx onder gelijktijdige druk", all(s < 500 for s in statussen),
           f"statussen {dict(statussen)}", "HOOG")
controleer("het saldo is geen cent veranderd", voor == na,
           f"voor {voor}, na {na} -- er is geld weggelekt op een mislukte bestelling", "KRITIEK")

# --- 2. Twintig keer tegelijk inloggen ------------------------------------
res = parallel(20, lambda i: roep("POST", "/auth/login", {"email": EMAIL, "password": PW}))
st = Counter(s for s, _, _, _ in res)
controleer("twintig gelijktijdige logins geven geen 5xx", all(s < 500 for s in st),
           f"statussen {dict(st)}", "HOOG")
print(f"  login-statussen: {dict(st)}")

# --- 3. Dezelfde sessie vijftig keer tegelijk gebruiken -------------------
res = parallel(50, lambda i: roep("GET", "/auth/me", token=token))
st = Counter(s for s, _, _, _ in res)
tijden = sorted(dt for _, _, dt, _ in res)
controleer("vijftig gelijktijdige verzoeken op één sessie: geen 5xx",
           all(s < 500 for s in st), f"statussen {dict(st)}", "HOOG")
print(f"  statussen {dict(st)}, mediaan {tijden[len(tijden)//2]*1000:.0f} ms, "
      f"traagste {tijden[-1]*1000:.0f} ms")

# --- 4. TOTP-opzet tien keer tegelijk -------------------------------------
res = parallel(10, lambda i: roep("GET", "/auth/totp/setup", token=token))
st = Counter(s for s, _, _, _ in res)
geheimen = {json.dumps(b.get("secret") or b.get("uri", ""))[:40] for _, b, _, _ in res}
controleer("gelijktijdige TOTP-opzet geeft geen 5xx", all(s < 500 for s in st),
           f"statussen {dict(st)}", "HOOG")
print(f"  TOTP-opzet: {dict(st)}, {len(geheimen)} verschillende geheimen")

# --- 5. Back-up maken op een VPS die niet van mij is, tien keer tegelijk ---
res = parallel(10, lambda i: roep("POST", "/vpses/b734cc0f-2b46-449e-9a53-6082c5fd2f51/backups",
                                  {}, token=token))
st = Counter(s for s, _, _, _ in res)
controleer("tien keer tegelijk op andermans VPS: nog steeds geweigerd",
           all(s in (403, 404, 429) for s in st), f"statussen {dict(st)}", "KRITIEK")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
