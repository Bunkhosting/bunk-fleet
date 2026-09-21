"""3. Rare invoer. Niets hiervan hoort een 500 op te leveren.

Het verschil dat telt: 4xx is "nee, en daarom", 5xx is "de server viel om".
Het eerste is een grens, het tweede is een bug -- en vaak een die met de juiste
invoer verder te duwen is.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 3. Invoer en randgevallen ==")

ROMMEL = [
    "", " ", "\t\n", "0", "-1", "null", "undefined", "NaN", "Infinity",
    "' OR 1=1 --", "\"; DROP TABLE vpses; --", "${jndi:ldap://x/a}",
    "<script>alert(1)</script>", "../../../../etc/passwd", "%00", "\x00afgebroken",
    "a" * 10000, "🙂" * 100, "‮gnirts", "{{7*7}}", "%s%s%s%s%n",
    "00000000-0000-0000-0000-000000000000", "not-a-uuid", "1 OR 1=1",
]

# --- id's in het pad -------------------------------------------------------
for r in ROMMEL:
    pad = "/vpses/" + urllib.parse.quote(r, safe="")
    status, body, _, _ = roep("GET", pad, token=token)
    controleer(f"GET /vpses/{r[:22]!r} -> geen 5xx", status < 500,
               f"status {status}: {str(body)[:160]}", "HOOG")

# --- velden in een body ----------------------------------------------------
for r in ROMMEL[:14]:
    status, body, _, _ = roep("POST", "/vpses",
                              {"package_id": r, "os": r, "label": r,
                               "region_code": r, "immediate_delivery_consent": True},
                              token=token)
    controleer(f"POST /vpses met {r[:22]!r} -> geen 5xx", status < 500,
               f"status {status}: {str(body)[:160]}", "HOOG")

# --- verkeerde typen -------------------------------------------------------
GEKKE_TYPEN = [
    {"package_id": [1, 2, 3]}, {"package_id": {"a": 1}}, {"package_id": True},
    {"package_id": 1e309}, {"package_id": -2**63}, {"package_id": 2**63},
    {"label": ["lijst"]}, {"label": {"diep": {"dieper": {"nog dieper": 1}}}},
    {"immediate_delivery_consent": "ja"}, {"immediate_delivery_consent": 1},
]
for data in GEKKE_TYPEN:
    status, body, _, _ = roep("POST", "/vpses", data, token=token)
    controleer(f"POST /vpses {str(data)[:40]} -> geen 5xx", status < 500,
               f"status {status}: {str(body)[:160]}", "HOOG")

# --- kapotte JSON en rare content-types ------------------------------------
for ruw, ct in [(b"{niet echt json", "application/json"),
                (b"", "application/json"),
                (b"[]", "application/json"),
                (b"null", "application/json"),
                (b'{"a":' + b"[" * 2000 + b"]" * 2000 + b"}", "application/json"),
                (b"<xml/>", "application/xml"),
                (b"a=1&b=2", "application/x-www-form-urlencoded")]:
    req = urllib.request.Request(API + "/vpses", data=ruw, method="POST",
                                 headers={"Content-Type": ct, "Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            status = r.status
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception as e:
        status = 0
    controleer(f"body {ruw[:18]!r} ({ct}) -> geen 5xx", 0 < status < 500,
               f"status {status}", "HOOG")

# --- enorme header en lange URL -------------------------------------------
status, _, _, _ = roep("GET", "/auth/me", token=token, headers={"X-Groot": "a" * 8000})
controleer("een header van 8 kB -> geen 5xx", status < 500, f"status {status}", "MIDDEL")

status, _, _, _ = roep("GET", "/vpses?" + "x=1&" * 2000, token=token)
controleer("een URL met 2000 parameters -> geen 5xx", status < 500, f"status {status}", "MIDDEL")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
