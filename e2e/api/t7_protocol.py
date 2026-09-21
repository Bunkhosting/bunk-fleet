"""7. Wat de server over zichzelf prijsgeeft, en wat een cache van hem mag bewaren."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 7. Headers, caching en methoden ==")

# --- caching van persoonlijke gegevens ------------------------------------
for pad in ["/auth/me", "/billing/wallet", "/vpses"]:
    status, _, _, h = roep("GET", pad, token=token)
    cc = (h.get("Cache-Control") or "").lower()
    controleer(f"{pad} mag niet in een gedeelde cache",
               "no-store" in cc or "private" in cc or "no-cache" in cc,
               f"Cache-Control: {cc or '(ontbreekt)'}", "HOOG")

# --- CORS: mag een vreemde site dit met jouw cookie lezen? ----------------
status, _, _, h = roep("GET", "/auth/me", token=token,
                       headers={"Origin": "https://kwaadaardig.example"})
acao = h.get("Access-Control-Allow-Origin")
acac = (h.get("Access-Control-Allow-Credentials") or "").lower()
controleer("geen open CORS naar een vreemde origin",
           acao in (None, "", "https://app.bunkhosting.nl") or acac != "true",
           f"Allow-Origin: {acao}, Allow-Credentials: {acac}", "KRITIEK")

# --- verraadt een fout de binnenkant? -------------------------------------
status, body, _, h = roep("GET", "/vpses/niet-eens-een-uuid", token=token)
tekst = str(body).lower()
for woord in ["elixir", "ecto", "postgrex", "stacktrace", "** (", "lib/control_plane"]:
    controleer(f"de foutmelding noemt {woord!r} niet", woord not in tekst,
               f"antwoord: {str(body)[:200]}", "MIDDEL")

controleer("de server noemt zijn versie niet in de headers",
           not any("phoenix" in str(v).lower() or "cowboy" in str(v).lower()
                   for v in h.values()),
           f"headers: {dict(list(h.items())[:8])}", "LAAG")

# --- methoden die er niet horen te zijn -----------------------------------
for methode in ["TRACE", "TRACK", "CONNECT", "PATCH", "PUT"]:
    status, _, _, _ = roep(methode, "/auth/me", token=token)
    controleer(f"{methode} /auth/me wordt niet uitgevoerd", status in (0, 400, 404, 405, 501),
               f"status {status}", "MIDDEL")

# --- kop-injectie via een veld dat teruggegeven wordt ---------------------
status, body, _, h = roep("POST", "/vpses",
                          {"package_id": 1, "os": "ubuntu-22.04",
                           "label": "kwaad\r\nX-Ingespoten: ja",
                           "immediate_delivery_consent": True}, token=token)
controleer("een label met regeleindes levert geen ingespoten header op",
           "X-Ingespoten" not in h and status < 500,
           f"status {status}, headers {list(h)[:10]}", "HOOG")

# --- Host-header --------------------------------------------------------
status, body, _, h = roep("GET", "/auth/me", token=token,
                          headers={"Host": "kwaadaardig.example"})
controleer("een vreemde Host-header levert geen doorverwijzing daarheen op",
           "kwaadaardig.example" not in str(h.get("Location", "")) and status < 500,
           f"status {status}, Location {h.get('Location')}", "HOOG")

# --- beveiligingsheaders op een ingelogd antwoord -------------------------
status, _, _, h = roep("GET", APP + "/dashboard", token=token)
for kop, verwacht in [("X-Frame-Options", "deny"), ("X-Content-Type-Options", "nosniff"),
                      ("Strict-Transport-Security", "max-age")]:
    waarde = (h.get(kop) or "").lower()
    controleer(f"{kop} staat op de ingelogde pagina", verwacht in waarde,
               f"{kop}: {waarde or '(ontbreekt)'}", "MIDDEL")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
