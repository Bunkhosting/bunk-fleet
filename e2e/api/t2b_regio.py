import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harnas import *
token = inloggen()
print("== 2b. Regio verplaatsen op andermans node, met de juiste velden ==")
ANDERMANS_NODE = "5e3480ca-2b8d-44fb-8e01-cb3e37a584cb"

# Geldige vorm, bestaand regio-id-achtig UUID dat niet bestaat: als eigenaarschap
# eerst wordt gecontroleerd is dit 404 en niet 422.
status, body, _, _ = roep("POST", f"/nodes/{ANDERMANS_NODE}/region",
                          {"region_id": "11111111-2222-3333-4444-555555555555"}, token=token)
controleer("region_id op andermans node: 404 (eigenaarschap eerst)", status == 404,
           f"status {status}: {body}", "KRITIEK")

# Een naam die al bestaat: mag geen regio aanmaken en mag niets verplaatsen.
status, body, _, _ = roep("POST", f"/nodes/{ANDERMANS_NODE}/region",
                          {"region_name": "Eindhoven"}, token=token)
controleer("region_name op andermans node wordt geweigerd", status in (403, 404),
           f"status {status}: {body}", "KRITIEK")

# Een naam die NIET bestaat: als de eigenaarscontrole erna zou komen, stond er nu
# een nieuwe locatie in het beheerscherm van iemand anders.
status, body, _, _ = roep("POST", f"/nodes/{ANDERMANS_NODE}/region",
                          {"region_name": "Testlocatie Harnas 9271"}, token=token)
controleer("een vreemde kan geen locatie aanmaken via andermans node",
           status in (403, 404), f"status {status}: {body}", "KRITIEK")
print(json.dumps({"goed": tellers["goed"], "fout": tellers["fout"]}))
