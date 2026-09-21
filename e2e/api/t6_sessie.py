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
status, body, _, headers = roep("POST", "/auth/login", {"email": EMAIL, "password": PW})
cookie = headers.get("Set-Cookie", "")
controleer("de sessiecookie is HttpOnly", "httponly" in cookie.lower(),
           f"Set-Cookie: {cookie[:160]}", "HOOG")
controleer("de sessiecookie is Secure", "secure" in cookie.lower(),
           f"Set-Cookie: {cookie[:160]}", "HOOG")
controleer("de sessiecookie heeft SameSite", "samesite" in cookie.lower(),
           f"Set-Cookie: {cookie[:160]}", "HOOG")

# --- verkeerd wachtwoord ---------------------------------------------------
status, body, _, _ = roep("POST", "/auth/login", {"email": EMAIL, "password": PW + "x"})
controleer("verkeerd wachtwoord geeft geen sessie", status >= 400 and "token" not in str(body),
           f"status {status}: {str(body)[:120]}", "KRITIEK")
controleer("de foutmelding verraadt niet of het adres bestaat",
           "wachtwoord" not in str(body).lower() or "onbekend" not in str(body).lower(),
           f"antwoord: {str(body)[:160]}", "LAAG")

status, body, _, _ = roep("POST", "/auth/login", {"email": "bestaatniet@bunk.test", "password": PW})
status2, body2, _, _ = roep("POST", "/auth/login", {"email": EMAIL, "password": "fout"})
controleer("onbekend adres en fout wachtwoord geven hetzelfde antwoord",
           status == status2 and str(body) == str(body2),
           f"{status}:{str(body)[:80]} vs {status2}:{str(body2)[:80]}", "MIDDEL")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
