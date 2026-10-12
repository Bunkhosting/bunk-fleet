"""6. Sessies: blijft een token dood als hij dood hoort te zijn?

Een uitgelogde sessie die nog werkt is erger dan geen uitlogknop: iemand denkt
dat hij weg is van een gedeelde computer.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

print("== 6. Sessies en tokens ==")

# --- uitloggen doodt precies één sessie ------------------------------------
een, twee = inloggen(), inloggen()
controleer("twee logins geven twee verschillende tokens", een != twee, "zelfde token!", "HOOG")

status, _, _, _ = roep("DELETE", "/auth/logout", token=een)
controleer("uitloggen lukt", geslaagd(status), f"status {status}")

status, _, _, _ = roep("GET", "/auth/me", token=een)
controleer("de uitgelogde sessie is dood", status == 401, f"status {status}", "KRITIEK")

status, _, _, _ = roep("GET", "/auth/me", token=twee)
controleer("de andere sessie leeft nog", status == 200, f"status {status}", "MIDDEL")

# --- overal uitloggen doodt ze allemaal ------------------------------------
drie = inloggen()
status, _, _, _ = roep("DELETE", "/auth/logout/all", token=drie)
controleer("overal uitloggen lukt", geslaagd(status), f"status {status}")
for naam, t in (("die het commando gaf", drie), ("de oudere sessie", twee)):
    status, _, _, _ = roep("GET", "/auth/me", token=t)
    controleer(f"na 'overal uitloggen' is {naam} dood", status == 401, f"status {status}", "HOOG")

# --- twee keer uitloggen, en uitloggen zonder sessie -----------------------
vier = inloggen()
roep("DELETE", "/auth/logout", token=vier)
status, _, _, _ = roep("DELETE", "/auth/logout", token=vier)
controleer("twee keer uitloggen geeft geen 5xx", status < 500, f"status {status}", "MIDDEL")
status, _, _, _ = roep("DELETE", "/auth/logout")
controleer("uitloggen zonder sessie geeft geen 5xx", 0 < status < 500, f"status {status}", "MIDDEL")

# --- de cookie -------------------------------------------------------------
# Eerst de login-CSRF: met de juiste gegevens maar van een vreemde herkomst, of
# zonder herkomst, hoort er geen sessie uit te komen. De geslaagde login hierna
# is de tegenproef: alleen de Origin verschilt.
for naam, kop in (("een vreemde herkomst", {"Origin": "https://kwaadwillend.example"}),
                  ("een verzoek zonder herkomst", {})):
    status, body, _, headers = roep("POST", "/auth/login", {"email": EMAIL, "password": PW},
                                    headers=kop)
    controleer(f"{naam} kan niet inloggen",
               status == 403 and sessiecookie(headers) is None,
               f"status {status}: {str(body)[:80]}", "HOOG")

status, body, _, headers = roep("POST", "/auth/login", {"email": EMAIL, "password": PW},
                                headers=VAN_DASHBOARD)
cookie = next((c for c in headers.set_cookies if c.startswith("bunk_session=")), "")
waarde = sessiecookie(headers)
controleer("de login zet een sessiecookie", status == 200 and bool(waarde),
           f"status {status}, Set-Cookie: {cookie[:60]}", "HOOG")
# Het token hoort alleen in de HttpOnly-cookie. Staat het ook in de body, dan
# leest elke XSS het en is de HttpOnly-vlag voor niets.
controleer("het login-antwoord bevat geen token", "token" not in body
           and (not waarde or waarde not in json.dumps(body)),
           f"body-sleutels: {sorted(body)[:10]}", "HOOG")
# Alleen de cookie, geen Authorization-header: zo doet de browser het.
status, _, _, _ = roep("GET", "/auth/me", headers={"Cookie": f"bunk_session={waarde}"})
controleer("alleen de cookie is genoeg om ingelogd te zijn", status == 200,
           f"status {status}", "HOOG")
# En een wijzigend verzoek op alleen die cookie, van een vreemde herkomst, wordt
# geweigerd: dat is de CSRF-bescherming nu de browser niets anders meer heeft.
status, body2, _, _ = roep("DELETE", "/auth/logout",
                           headers={"Cookie": f"bunk_session={waarde}",
                                    "Origin": "https://kwaadwillend.example"})
controleer("een vreemde herkomst kan niet uitloggen met de cookie", status == 403,
           f"status {status}: {str(body2)[:80]}", "HOOG")
# Daarna netjes uitloggen vanaf de eigen herkomst; de sessie hoort dan dood.
roep("DELETE", "/auth/logout", headers={"Cookie": f"bunk_session={waarde}", "Origin": APP})
status, _, _, _ = roep("GET", "/auth/me", headers={"Cookie": f"bunk_session={waarde}"})
controleer("uitloggen via de cookie doodt de sessie", status == 401, f"status {status}", "HOOG")
controleer("de sessiecookie is HttpOnly", "httponly" in cookie.lower(),
           f"Set-Cookie: {cookie[:160]}", "HOOG")
controleer("de sessiecookie is Secure", "secure" in cookie.lower(),
           f"Set-Cookie: {cookie[:160]}", "HOOG")
controleer("de sessiecookie heeft SameSite", "samesite" in cookie.lower(),
           f"Set-Cookie: {cookie[:160]}", "HOOG")

# --- verkeerd wachtwoord ---------------------------------------------------
status, body, _, _ = roep("POST", "/auth/login", {"email": EMAIL, "password": PW + "x"},
                          headers=VAN_DASHBOARD)
controleer("verkeerd wachtwoord geeft geen sessie", status >= 400 and "token" not in str(body),
           f"status {status}: {str(body)[:120]}", "KRITIEK")
controleer("de foutmelding verraadt niet of het adres bestaat",
           "wachtwoord" not in str(body).lower() or "onbekend" not in str(body).lower(),
           f"antwoord: {str(body)[:160]}", "LAAG")

status, body, _, _ = roep("POST", "/auth/login",
                          {"email": "bestaatniet@bunk.test", "password": PW},
                          headers=VAN_DASHBOARD)
status2, body2, _, _ = roep("POST", "/auth/login", {"email": EMAIL, "password": "fout"},
                            headers=VAN_DASHBOARD)
controleer("onbekend adres en fout wachtwoord geven hetzelfde antwoord",
           status == status2 and str(body) == str(body2),
           f"{status}:{str(body)[:80]} vs {status2}:{str(body2)[:80]}", "MIDDEL")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
