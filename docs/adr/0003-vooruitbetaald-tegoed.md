# 0003 — Klanten betalen uit vooruitbetaald tegoed

**Aanleiding.** Klanten betalen per VPS per maand, en moeten kunnen betalen met
iDEAL en Bancontact.

**Besluit.** Een klant waardeert zijn tegoed op via Mollie. Een bestelling en elke
maandelijkse verlenging worden afgeschreven van dat tegoed, in een grootboek
(`ledger_entries`). Is het tegoed op bij een verlenging, dan wordt de VPS
gestopt en het abonnement `past_due`; de klant kan hem dan niet zelf starten,
en hij start vanzelf weer zodra een volgende poging slaagt.

**Waarom.** iDEAL kent geen automatische incasso zoals een creditcard dat doet.
Vooraf betalen voorkomt dat er gefactureerd wordt voor iets wat nooit betaald
wordt, en maakt elke afschrijving een simpele, controleerbare boeking.

**Belangrijke regels.**
- Het bedrag van een Mollie-betaling wordt nooit uit de webhook gelezen, maar
  opgehaald bij Mollie zelf (fetch-to-verify).
- Elke afschrijving voor een VPS draagt het `vps_id`. Een afschrijving zonder
  `vps_id` betekent "de VPS is nooit aangemaakt", en wordt na tien minuten
  automatisch terugbetaald. Een afschrijving die dat veld vergeet, wordt dus
  teruggestort; zo ging het bijna met elke verlenging (zie de commit van
  2026-10-09).
- Afschrijven gebeurt onder een slot per gebruiker (`Locks.take(:wallet, …)`),
  gedeeld door bestelling en verlenging.

**Alternatieven.** Achteraf factureren (risico op wanbetaling, incasso nodig);
abonnementen bij Mollie zelf (vraagt een mandaat, en dat kan niet met iDEAL
alleen).

**Gevolgen.** Een klant zonder tegoed kan niet bestellen. Terugbetalen is een
grootboekboeking, geen Mollie-refund.
