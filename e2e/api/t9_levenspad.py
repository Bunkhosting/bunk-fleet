"""9. Wat een klant met een draaiende VPS kan, en wat er gebeurt bij drammen."""
import sys, os, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 9. Levenspad van een draaiende VPS ==")

_, lijst, _, _ = roep("GET", "/vpses", token=token)
vpsen = lijst_uit(lijst)
controleer("de bestelde VPS staat in de lijst", len(vpsen) == 1, f"kreeg {len(vpsen)}", "HOOG")
vps = vpsen[0]
vid = vps["id"]
print(f"  VPS {vid[:8]} status={vps.get('status')} pakket={json.dumps(vps.get('package'))[:80]}")

# --- detail ---------------------------------------------------------------
status, detail, _, _ = roep("GET", f"/vpses/{vid}", token=token)
controleer("het detail is op te vragen", status == 200, f"status {status}")
controleer("er staat geen consolesleutel in het antwoord",
           "private" not in json.dumps(detail).lower() and "BEGIN" not in json.dumps(detail),
           f"{json.dumps(detail)[:200]}", "KRITIEK")

# --- hernoemen ------------------------------------------------------------
status, body, _, _ = roep("PATCH", f"/vpses/{vid}", {"name": "harnas-hernoemd"}, token=token)
controleer("hernoemen lukt", status in (200, 204), f"status {status}: {str(body)[:140]}")
status, body, _, _ = roep("PATCH", f"/vpses/{vid}", {"name": "<script>alert(1)</script>"}, token=token)
controleer("een naam met markup wordt geweigerd of ontdaan",
           status >= 400 or "<script>" not in json.dumps(body),
           f"status {status}: {str(body)[:140]}", "HOOG")

# --- console-ticket -------------------------------------------------------
status, ticket, _, _ = roep("POST", f"/vpses/{vid}/console-ticket", {}, token=token)
controleer("een console-ticket wordt afgegeven", status in (200, 201),
           f"status {status}: {str(ticket)[:140]}", "HOOG")
kaartje = (ticket or {}).get("ticket") or (ticket or {}).get("token")
if kaartje:
    controleer("het ticket is niet te raden (lang genoeg)", len(str(kaartje)) >= 20,
               f"lengte {len(str(kaartje))}", "HOOG")
    status2, t2, _, _ = roep("POST", f"/vpses/{vid}/console-ticket", {}, token=token)
    tweede = (t2 or {}).get("ticket") or (t2 or {}).get("token")
    controleer("twee tickets zijn verschillend", kaartje != tweede, "zelfde ticket!", "HOOG")

# --- tien keer tegelijk herstarten ---------------------------------------
with cf.ThreadPoolExecutor(max_workers=10) as pool:
    res = [f.result() for f in [pool.submit(roep, "POST", f"/vpses/{vid}/reboot", {}, token)
                                for _ in range(10)]]
st = Counter(s for s, _, _, _ in res)
print(f"  tien gelijktijdige herstarts: {dict(st)}")
controleer("tien gelijktijdige herstarts geven geen 5xx", all(geslaagd(s) for s in st),
           f"statussen {dict(st)}", "HOOG")

time.sleep(2)
_, cmds, _, _ = roep("GET", f"/vpses/{vid}", token=token)
# Het detail komt als {"vps": {...}} terug; de lijst als {"vpses": [...]}.
na = (cmds or {}).get("vps", cmds) or {}
controleer("de VPS is niet in een rare toestand beland",
           na.get("status") in ("active", "ACTIVE", "rebooting", "provisioning"),
           f"status {na.get('status')} uit {json.dumps(cmds)[:140]}", "HOOG")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
