# Bunk Fleet

De orkestratie-monorepo van **Bunk Hosting**: een VPS-platform op eigen
hardware. Een centrale **control plane** plant en beheert een verzameling
**worker nodes**; klanten kiezen een regio en een pakket, en de control plane
zet de VPS op een node met ruimte. Klanten zien of kiezen geen node.

De opzet leunt op Fly.io: een fouttolerante Elixir/Phoenix control plane
verdraagt veel gelijktijdige, wankele agentverbindingen en multiplext realtime
consoles, terwijl een kleine Go-agent op elke node naar *buiten* belt — een node
heeft daardoor geen inkomende poort nodig.

## Wat staat waar

| Pad              | Wat het is                                                                   |
| ---------------- | ---------------------------------------------------------------------------- |
| `control_plane/` | Phoenix 1.7-app (OTP-app `:control_plane`), Elixir ~> 1.14, Postgres via Ecto. |
| `agent/`         | Go 1.25-module `github.com/Bunk-Hosting/bunk-fleet/agent`, statisch gebouwd.   |
| `frontend/`      | Klantendashboard, Next.js 14 / TypeScript.                                    |
| `provisioning/`  | Wat er op een nieuwe VPS terechtkomt (o.a. het welkomstscherm).               |
| `tools/`         | De kwaliteitspoort en de back-up-/herstelscripts.                            |
| `docs/`          | Protocol, architectuur, runbooks, security- en privacyreviews.                |

De frontend praat met de control plane via `/api/v1` (bearer-auth); de agent
belt uit naar de control plane (enroll → heartbeat → command long-poll →
result).

## Architectuur

```
                          ┌───────────────────────────────────────────┐
                          │             CONTROL PLANE                  │
                          │        (Elixir / Phoenix 1.7, OTP)         │
                          │                                            │
  klanten / API ───────▶  │  scheduler   enrollment   console mux      │
                          │  Ecto ─▶ Postgres                          │
                          └───────────────┬────────────────────────────┘
                                          │  HTTPS: enroll, heartbeat,
                                          │  command long-poll, result.
                                          │  Bearer agent-token per node.
                                          │  DE AGENT BELT UIT (geen inkomende poort)
              ┌───────────────────────────┼───────────────────────────┐
              │                           │                           │
        ┌─────┴──────┐              ┌──────┴─────┐              ┌──────┴─────┐
        │ bunk-agent │              │ bunk-agent │              │ bunk-agent │
        │   (Go)     │              │   (Go)     │              │   (Go)     │
        │  node 1    │              │  node 2    │              │  node 3    │
        └─────┬──────┘              └──────┬─────┘              └──────┬─────┘
              │ lokale API                 │ lokale API                │ lokale API
        ┌─────┴──────┐              ┌──────┴─────┐              ┌──────┴─────┐
        │  Proxmox   │              │  Proxmox   │              │   ESXi     │
        │   (VMs)    │              │   (VMs)    │              │   (VMs)    │
        └────────────┘              └────────────┘              └────────────┘
```

### Onderdelen

- **Control plane** — de bron van waarheid. Doet enrollment, houdt inventaris en
  capaciteit bij, draait de scheduler, handelt klant- en API-verzoeken af en
  multiplext consoles terug naar de gebruiker. Elixir/OTP vanwege fouttolerantie
  en het aantal gelijktijdige verbindingen.
- **Agent (`bunk-agent`)** — één per node. Meldt zich aan met een eenmalig
  token, stuurt periodiek capaciteit door, haalt werk op met long-polling, voert
  provision-, delete-, power- en consolecommando's uit tegen de lokale
  hypervisor. Go zonder externe afhankelijkheden, één statische binary.
- **Providers** — de hypervisorkant van de agent: **Proxmox** en
  **ESXi/vCenter**. De control plane kent maar één commandovocabulaire.
- **Scheduler** (`control_plane/lib/control_plane/fleet/scheduler.ex`) — de klant
  kiest een **regio**; de plaatsing gaat naar de node *in die regio* die daarna
  de meeste ruimte overhoudt. Kandidaatrijen worden gelockt, zodat gelijktijdige
  plaatsingen een node niet kunnen overboeken.

### Hoe een klant bij zijn VPS komt

Via de **webterminal in het dashboard**, en voorlopig alleen daar. De keten is:

```
browser (WebSocket) ─▶ relay (loopback TCP) ─▶ SSH-client ín de control plane
                                             ─▶ agent (WebSocket) ─▶ VPS:22
```

De relay vervoert SSH-bytes, geen tekst: de control plane is zelf de
SSH-client. Er staan bewust geen poort-forwards naar VPS'en open en `public_host`
is leeg — zie [`docs/runbooks/`](docs/runbooks/).

### Wat er verder in de control plane zit

Betalingen via **Mollie** (webhooks worden fetch-to-verify afgehandeld; welke
betaalmethodes aanstaan is een instelling in het Mollie-account, niet in deze
repo),
botverificatie op registratie via **Cloudflare Turnstile**, een grootboek met
tegoeden en dagelijkse afschrijving, en elke nacht een versleutelde back-up van
de database (`tools/backup.sh`, herstel met `tools/restore.sh`).

## Aan de slag

```bash
make check   # de poort: format, compile --warnings-as-errors, credo --strict,
             # deps.audit, test en dialyzer, plus gofmt/vet/test voor de agent
make test    # alleen de tests van beide componenten
make build   # bouwt beide
make fmt     # formatteert beide
```

Per component:

```bash
cd control_plane && mix deps.get && mix test
cd agent         && go build ./... && go test ./...
```

`make check` is wat een wijziging moet halen voor hij uitgerold wordt; draai hem
voordat je commit.

## Documentatie

- [`docs/architecture.md`](docs/architecture.md) — lagen, stack, scheduling,
  faalmodi en de gefaseerde roadmap.
- [`docs/protocol.md`](docs/protocol.md) — het contract tussen agent en control
  plane (Enroll, Heartbeat, Command, CommandResult), transport en beveiliging.
- [`docs/runbooks/`](docs/runbooks/) — een node toevoegen, back-up en herstel, een betaling die niet aankwam.
- [`docs/security/`](docs/security/) — securitybeoordeling en het
  misuse-caseregister.
- [`docs/privacy/`](docs/privacy/) — de AVG-beoordeling.
- [`docs/design/multi-node.md`](docs/design/multi-node.md) — het ontwerp voor
  meerdere nodes.
- [`CODE_GUIDELINES.md`](CODE_GUIDELINES.md) — hoe hier geschreven wordt.
