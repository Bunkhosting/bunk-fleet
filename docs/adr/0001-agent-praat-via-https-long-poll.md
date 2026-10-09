# 0001 — De agent praat via HTTPS long-poll met een token per node

**Aanleiding.** Elke hypervisor draait een agent die commando's moet ontvangen
(uitrollen, verwijderen, back-ups) en terugmelden. De oorspronkelijke opzet in
`docs/protocol.md` beschreef mTLS met een gRPC- of WebSocket-kanaal.

**Besluit.** De agent haalt zijn werk op met een long-poll naar `GET /v1/commands`
en meldt resultaten met `POST /v1/commands/:id/result`, over HTTPS, met een
bearer-token dat hij bij de inschrijving kreeg. De hartslag (`POST /v1/heartbeat`)
draagt capaciteit en meldingen heen, en instellingen uit het paneel terug. De
webterminal is de uitzondering: die gebruikt een WebSocket-relay, omdat het om
een interactieve stroom gaat.

**Waarom.** Een node staat vaak achter NAT of een router die de eigenaar niet
beheert. Een uitgaande HTTPS-verbinding werkt overal; een inkomende niet.
Long-poll vraagt geen blijvende verbinding om te bewaken, en een gemiste
aflevering wordt vanzelf opnieuw uitgedeeld (zie `deliverable_commands_for_node`).

**Alternatieven.** mTLS met een eigen CA: sterker tegen een gestolen token, maar
een CA beheren voor een handvol nodes is meer werk dan het oplevert zolang het
token per node is en server-side gecontroleerd wordt. Een permanente WebSocket:
snellere aflevering, maar herverbinden, hartslag op het kanaal en afleveren-na-
verbreken moeten dan allemaal zelf gebouwd worden.

**Gevolgen.**
- Elk commando moet idempotent zijn: herlevering is normaal. De agent voert een
  commando één keer uit en meldt het resultaat zo vaak als erom gevraagd wordt
  (`memo.go`).
- Een commando kan tot ~2 s wachten voordat het wordt opgehaald.
- Een gestolen agent-token geeft toegang tot de commando's van die ene node, niet
  meer: elke `/v1`-route is aan de node van het token gebonden.
- `docs/protocol.md` beschrijft nog de oude opzet en moet worden bijgewerkt.
