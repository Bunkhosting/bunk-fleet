# 0002 — De webterminal is de enige ingang tot een VPS

**Aanleiding.** Een klant moet in zijn VPS kunnen. Bij gedeeld IPv4 krijgt een
VPS geen eigen publiek adres.

**Besluit.** De klant komt binnen via de webterminal in het dashboard. De browser
praat met het control plane, dat via de agent op de node een SSH-sessie naar het
privé-adres van de VPS opent. SSH van buitenaf en port forwards worden bewust
niet aangeboden.

**Waarom.** Geen enkele VPS hangt met een open SSH-poort aan het internet, dus
geen brute force op klantmachines en geen misbruikklachten daarover. De ingang
loopt door het dashboard, dus achter de login, de 2FA en de autorisatie per VPS
van het control plane.

**Alternatieven.** Een publieke poort per VPS via DNAT (de code daarvoor bestaat
nog, maar staat uit omdat geen node een `public_host` heeft). Een eigen IPv4 per
VPS: duur en schaars.

**Gevolgen.**
- De agent moet bij elke VPS op zijn node kunnen. Een node waar dat niet lukt,
  verkoopt machines waar de klant niet in komt. De agent meldt dat daarom zelf
  (`network_note`, `netwerkstatus.go`).
- Het control plane heeft een sleutel waarmee het op elke VPS inlogt. Die is
  het meest gevoelige geheim van het platform.
- De agent laat alleen verbindingen toe naar adressen binnen het VPS-net van
  zijn node (`allowedConsoleTarget`).
