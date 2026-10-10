# Configuratie

Alle omgevingsvariabelen die het control plane en de agent lezen. De bron van
waarheid is de code: `control_plane/config/runtime.exs` (en `config.exs`,
`lib/control_plane/mailer/config.ex`) en `agent/internal/config/config.go`. Een
variabele die daar bijkomt, hoort hier ook bij te komen.

Geheimen staan alleen in `.env.prod` op de productiemachine (root, 0640) en nooit
in git; de geheimenscan in de CI houdt dat tegen. Zie
[ADR 0004](adr/0004-uitrollen-vanaf-main-op-de-productiemachine.md).

## Control plane

Alleen in productie gelezen (`runtime.exs`, blok `config_env() == :prod`), tenzij
anders vermeld.

| Variabele | Verplicht | Standaard | Wat |
|---|---|---|---|
| `DATABASE_URL` | ja | — | Postgres, `ecto://gebruiker:wachtwoord@host/db`. Start niet zonder |
| `SECRET_KEY_BASE` | ja | — | Ondertekent cookies en tokens. Start niet zonder |
| `PHX_HOST` | ja | — | Hostnaam (`app.bunkhosting.nl`). Start niet zonder: hiervan worden links in mails gebouwd |
| `PUBLIC_URL` | nee | `https://` + `PHX_HOST` | Publiek adres; ook de enige herkomst die `Plugs.SameOrigin` toelaat |
| `PORT` | nee | `4000` | Poort binnen de container |
| `PHX_SERVER` | nee | — | `true` om de webserver te starten (in de release) |
| `POOL_SIZE` | nee | `10` | Databaseverbindingen |
| `ECTO_IPV6` | nee | — | `true` om Postgres over IPv6 te bereiken |
| `DNS_CLUSTER_QUERY` | nee | — | Ongebruikt: er draait één control plane |
| `BUNK_BUILD_VERSION` | nee | — | Build-stempel; de update-golf leest hieraan af welke agents bij zijn |
| `ADMIN_TOKEN` | nee | — | Gedeeld geheim voor `/admin/v1`. Leeg = die API staat uit. Elke handeling komt in `beheer_audit` |
| `CONSOLE_SSH_PRIVATE_KEY` | ja | — | Base64 van de sleutel waarmee het control plane op VPS'en inlogt (webterminal) |
| `CONSOLE_SSH_PUBLIC_KEY` | ja | — | Base64 van de bijbehorende publieke sleutel; gaat via cloud-init naar elke VPS |
| `CONSOLE_SSH_USER` | nee | `root` | Gebruiker voor de webterminal |
| `CONSOLE_KEY_ENC` | nee | — | Base64 van 32 bytes; zet per-VPS consolesleutels aan |
| `MOLLIE_API_KEY` | nee | — | Betalingen. Leeg = opwaarderen geeft `payments_unavailable` |
| `TURNSTILE_SECRET_KEY` | nee | — | Captcha bij registratie. Leeg = geen captcha (en dus botregistraties) |
| `SMTP_HOST` | nee | — | Mailserver. Leeg = er gaat geen mail uit (met een waarschuwing bij het opstarten) |
| `SMTP_PORT` | nee | `587` | |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | bij SMTP | — | |
| `SMTP_SSL` | nee | afgeleid van de poort | Impliciete TLS (465) of STARTTLS |
| `SMTP_CACERTFILE` | nee | castore | CA-bundel voor de mailserver |
| `MAIL_FROM_ADDRESS` | nee | `noreply@bunkhosting.nl` | Ook in dev/test |
| `MAIL_FROM_NAME` | nee | `Bunk Hosting` | Ook in dev/test |
| `OPS_EMAIL` | nee | — | Waar operationele meldingen heen gaan. Leeg = alleen in de log |
| `DEADMAN_URL` | nee | — | Wordt na elke volledige reconcilerronde aangeroepen; blijft hij uit, dan merkt een externe bewaker dat |
| `RATE_VCPU`, `RATE_RAM_GB`, `RATE_DISK_GB` | nee | `0.010`, `0.004`, `0.0002` | Verbruikstarief per uur per eenheid |
| `MAX_VPSES_PER_OWNER` | nee | `10` | Quotum per klant |

`SOME_APP_SSL_KEY_PATH` en `SOME_APP_SSL_CERT_PATH` staan nog in `runtime.exs` als
uitgecommentarieerd sjabloon van Phoenix; ze worden niet gebruikt (TLS eindigt bij
Cloudflare en de edge).

## Agent

Staan in `/etc/bunk-worker/agent.env` (of `/etc/bunk-agent/agent.env` op oudere
installaties), 0600. Elke variabele heeft ook een vlag met dezelfde naam in
kleine letters (`--manage-network`). Wat de eigenaar in het dashboard instelt,
komt via de hartslag binnen en gaat voor (zie [protocol](protocol.md)).

| Variabele | Standaard | Wat |
|---|---|---|
| `BUNK_CONTROL_PLANE_URL` | — | Adres van het control plane. HTTPS, of HTTP alleen naar een privé-adres |
| `BUNK_ENROLL_TOKEN` | — | Eenmalig token voor de eerste inschrijving. Daarna leeg |
| `BUNK_STATE_DIR` | `/var/lib/bunk-agent` (de installer zet `/var/lib/bunk-worker`) | `state.json` (identiteit) en `memo.json` (afgeronde commando's) |
| `BUNK_HYPERVISOR` | `proxmox` | `proxmox` of `esxi` |
| `BUNK_OWNER_EMAIL` | — | Eigenaar van de node bij de inschrijving |
| `BUNK_HEARTBEAT_INTERVAL` | `30s` | |
| `BUNK_MAX_PARALLEL_COMMANDS` | `4` | Hoeveel VPS'en tegelijk werk krijgen |
| `BUNK_OFFER_VCPU`, `BUNK_OFFER_RAM_MB`, `BUNK_OFFER_DISK_GB` | `0` (alles) | Wat de node aan de VPS-pool geeft |
| `BUNK_VCPU_OVERSUBSCRIBE` | `0` (standaard 3) | vCPU's per fysieke core |
| `BUNK_VMID_MIN`, `BUNK_VMID_MAX` | `0` | VMID-blok van Bunk; leeg = Proxmox kiest |
| `BUNK_VPS_BRIDGE` | — | Bridge voor VPS-netwerkkaarten |
| `BUNK_VPS_VLAN` | `0` | VLAN-tag; 0 = untagged |
| `BUNK_VPS_GATEWAY`, `BUNK_VPS_CIDR_PREFIX`, `BUNK_VPS_RANGE_START`, `BUNK_VPS_RANGE_END` | — | Het VPS-netwerk, als de operator het lokaal vastlegt |
| `BUNK_MANAGE_NETWORK` | `false` | Laat de agent de gateway, NAT en firewallregels zetten. **Niet aanzetten** als een router het gateway-adres al heeft |
| `BUNK_PROXMOX_HOST` | — | Bijvoorbeeld `https://127.0.0.1:8006` |
| `BUNK_PROXMOX_NODE` | — | Naam van de Proxmox-node |
| `BUNK_PROXMOX_TOKEN_ID`, `BUNK_PROXMOX_TOKEN_SECRET` | — | API-token |
| `BUNK_PROXMOX_VERIFY_SSL` | `true` | |
| `BUNK_PROXMOX_TLS_FINGERPRINT` | — | Vingerafdruk van een zelfondertekend certificaat, in plaats van verificatie uit te zetten |
| `BUNK_PROXMOX_BACKUP_STORAGE` | — | Opslag voor back-ups (vzdump) |
| `BUNK_ESXI_URL`, `BUNK_ESXI_USER`, `BUNK_ESXI_PASSWORD` | — | vSphere |
| `BUNK_ESXI_INSECURE` | `false` | |
| `BUNK_ESXI_DATACENTER`, `BUNK_ESXI_DATASTORE`, `BUNK_ESXI_RESOURCE_POOL`, `BUNK_ESXI_FOLDER`, `BUNK_ESXI_TEMPLATE` | — | Waar en waarvan gekloond wordt |
