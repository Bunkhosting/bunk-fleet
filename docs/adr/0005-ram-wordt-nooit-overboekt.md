# 0005 — RAM wordt nooit overboekt, vCPU wel

**Aanleiding.** Wat een node kan verkopen, hangt af van welke grondstof je mag
overboeken.

**Besluit.** RAM en schijf worden nooit overboekt: wat verkocht is, bestaat. vCPU
wordt standaard drie keer overboekt (per node instelbaar). De scheduler plaatst
een nieuwe VPS op de node met de meeste ruimte (`Node.headroom_score`), en houdt
zijn eigen boekhouding bij onder een slot per node, naast wat de agent meldt; het
laagste van de twee telt.

**Waarom.** Een VPS die zijn RAM niet krijgt, wordt door de kernel van de host
gestopt; dat is een storing. Een VPS die zijn vCPU deelt, is hooguit trager; de
meeste VPS'en doen het grootste deel van de tijd bijna niets. RAM is daardoor de
grondstof die de kostprijs bepaalt.

**Alternatieven.** Ook RAM overboeken (ballooning): meer verkopen per node, maar
een klant die zijn geheugen echt gebruikt, merkt het. Geen vCPU-overboeking:
eerlijk, maar dan staat het grootste deel van de CPU stil.

**Gevolgen.** vCPU is geen bindende grondstof bij het plaatsen. Ooit blokkeerde
een fout die vCPU wel liet tellen elke bestelling met een 409.
