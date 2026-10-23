"""11. Het foutcontract, zoals het in productie staat.

`tools/foutcodes.py` kijkt of elke code die we kúnnen sturen een zin heeft. Dat
is een papieren controle: hij leest twee bestanden en vergelijkt lijstjes. Wat
hij niet weet is of de uitgerolde versie die codes ook echt stuurt, en met welke
status.

Dit bestand vraagt het aan de draaiende dienst. Elke regel hieronder is een pad
dat een klant per ongeluk kan lopen, met het antwoord dat ernaast hoort te
staan. Loopt de tabel uit de pas met wat er draait, dan blijkt dat hier en niet
bij een klant.

Er wordt niets besteld en niets betaald: elk verzoek hieronder hoort geweigerd
te worden, en dat wordt ook nagemeten -- na afloop staat het saldo op hetzelfde
bedrag.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *

token = inloggen()
print("== 11. Het foutcontract ==")


def saldo():
    _, w, _, _ = roep("GET", "/billing/wallet", token=token)
    return w.get("balance_cents")


voor = saldo()

# Een geldige Starter-specificatie. Die hoort er te zijn, anders meet de helft
# hieronder iets anders dan hij denkt: een bestelling die op de specificatie
# strandt bereikt de controle erna nooit.
# Het is bewust een pakket dat het saldo NIET dekt (onbetaalbaar_pakket), zodat
# ook een bestelling die per ongeluk door de validatie komt op het tegoed strandt.
# Geen zo'n pakket: de gevallen die deze specificatie gebruiken worden overgeslagen.
STARTER = onbetaalbaar_pakket(token)
SPEC_LEEG = {"name": "harnas-nooit"}  # onvolledig, kan nooit een bestelling worden
BASIS = bestelling(STARTER) if STARTER else None
BASIS_ZONDER_TOESTEMMING = ({k: v for k, v in BASIS.items() if k != "immediate_delivery_consent"}
                            if BASIS else None)

GEVALLEN = [
    # (naam, methode, pad, body, verwachte status, verwachte code)
    ("een VPS die niet bestaat", "GET",
     "/vpses/11111111-1111-1111-1111-111111111111", None, 404, "not_found"),
    ("een VPS-id dat geen uuid is", "GET",
     "/vpses/geen-uuid", None, 404, "not_found"),
    ("een specificatie die het platform niet aankan", "POST", "/vpses",
     dict(SPEC_LEEG, vcpu=9999, ram_mb=9_999_999, disk_gb=99_999,
          immediate_delivery_consent=True), 422, "invalid_vps"),
    ("bestellen zonder toestemming voor directe levering", "POST", "/vpses",
     BASIS_ZONDER_TOESTEMMING, 422, "no_delivery_consent"),
    ("een regiocode die niet bestaat", "POST", "/vpses",
     dict(BASIS or {}, region_code="bestaat-niet"),
     422, "region_not_found"),
    ("een region_id dat geen uuid is", "POST", "/vpses",
     dict(BASIS or {}, region_id="geen-uuid"),
     422, "region_not_found"),
    ("opwaarderen met nul euro", "POST", "/billing/topup",
     {"amount_cents": 0}, 422, "invalid_amount"),
    ("opwaarderen met een negatief bedrag", "POST", "/billing/topup",
     {"amount_cents": -2500}, 422, "invalid_amount"),
    ("het beheerpaneel als gewone klant", "GET",
     "/beheer/stats", None, 403, "forbidden"),
]

for naam, methode, pad, body, status_verwacht, code_verwacht in GEVALLEN:
    if methode == "POST" and pad == "/vpses" and BASIS is None and "vcpu" not in (body or {}):
        print(f"  overgeslagen: {naam} (geen veilig te bestellen pakket)")
        continue
    status, antwoord, _, _ = roep(methode, pad, body, token=token)
    code = antwoord.get("error") if isinstance(antwoord, dict) else None

    controleer(f"{naam}: status {status_verwacht}",
               status == status_verwacht,
               f"kreeg {status} met {str(antwoord)[:140]}", "HOOG")
    controleer(f"{naam}: code {code_verwacht!r}",
               code == code_verwacht,
               f"kreeg {code!r}", "MIDDEL")

# Een bestelling die het tot de tegoedcontrole haalt hoort daar te stranden: het
# testaccount heeft minder dan een Starter kost. Dit is meteen de controle dat
# de weg ernaartoe open is -- zou dit 201 geven, dan staat er nu een VPS.
if BASIS:
    status, antwoord, _, _ = roep("POST", "/vpses", BASIS, token=token)
    controleer("een bestelling die het tegoed te boven gaat wordt geweigerd",
               status == 402 and antwoord.get("error") == "insufficient_credits",
               f"status {status}: {str(antwoord)[:160]}", "KRITIEK")
else:
    print("  overgeslagen: de 402-controle (geen pakket duurder dan het saldo).")

na = saldo()
controleer("en er is in deze hele reeks geen cent bewogen",
           na == voor, f"saldo {na} vs {voor}", "KRITIEK")

print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
