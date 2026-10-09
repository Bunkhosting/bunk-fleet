# Protocol tussen agent en control plane

Wat een node (de agent, `agent/`) en het control plane (`control_plane/`) tegen
elkaar zeggen. De bron van waarheid is de code: `agent/internal/transport/transport.go`
aan de kant van de agent, `control_plane/lib/control_plane_web/router.ex` (scope
`/v1`) en de controllers daarachter aan de andere kant. Wijkt dit document daarvan
af, dan klopt de code en is dit document verouderd.

Waarom het zo is opgezet en niet met mTLS of een permanente verbinding: zie
[ADR 0001](adr/0001-agent-praat-via-https-long-poll.md).

## Verbinding en authenticatie

- Alles over HTTPS. Plain HTTP alleen naar een privé-adres (`config.go`).
- Inschrijven met een eenmalig enroll-token. Daarna draagt elke aanvraag
  `Authorization: Bearer <agent_token>`. Elke `/v1`-route is gebonden aan de node
  van dat token: een node ziet en beantwoordt alleen zijn eigen commando's.
- De agent maakt alle verbindingen; het control plane belt nooit een node.

## Endpoints

| Methode en pad | Wie | Wat |
|---|---|---|
| `POST /v1/enroll` | agent, met enroll-token | Inschrijven; levert `node_id` en `agent_token` |
| `POST /v1/heartbeat` | agent | Capaciteit en meldingen heen, instellingen terug |
| `GET /v1/commands?node_id=…` | agent | Long-poll: commando's die deze node moet uitvoeren |
| `POST /v1/commands/:id/result` | agent | Uitkomst van één commando |
| `GET /v1/port-forwards` | agent | De gewenste port forwards, als volledige set |
| `GET /v1/console-relay` | agent (WebSocket) | De SSH-stroom van een webterminal |

## Inschrijven

Verzoek (`EnrollRequest`):

| Veld | Betekenis |
|---|---|
| `token` | Het eenmalige enroll-token uit het dashboard |
| `hypervisor` | `proxmox` of `esxi` |
| `agent_version` | De build van de agent |
| `vps_gateway`, `vps_cidr_prefix`, `vps_range_start`, `vps_range_end` | Optioneel: het VPS-netwerk dat de operator lokaal heeft ingesteld |
| `owner_email` | Optioneel: de eigenaar (het token wint als het er ook een noemt) |

Antwoord (`EnrollResponse`): `node_id`, `agent_token`, en `vps_network`
(`gateway`, `cidr_prefix`, `range_start`, `range_end`) zoals het control plane het
heeft toegekend. De agent bewaart dit in `state.json` (0600) en begint daar na een
herstart mee.

## Hartslag

Elke 30 seconden. Verzoek (`Heartbeat`):

| Veld | Betekenis |
|---|---|
| `node_id`, `at` | Wie en wanneer |
| `total_vcpu`, `avail_vcpu`, `total_ram_mb`, `avail_ram_mb`, `total_disk_gb`, `avail_disk_gb` | Capaciteit, al afgetopt op wat de eigenaar aanbiedt |
| `agent_version` | De draaiende build; de update-golf leest hieraan af wie bij is |
| `capacity_error` | Gezet als de agent zijn hypervisor niet kon bevragen, of als netwerkbeheer aantoonbaar mislukte. De node blijft zichtbaar maar krijgt geen nieuwe VPS'en |
| `network_note` | Een vermoeden dat niets blokkeert: de agent komt mogelijk niet bij zijn VPS'en, of klanten zijn niet van elkaar afgeschermd. Weggelaten = opgelost |

Antwoord: `{"settings": {...}}` (`NodeSettings`). Elk veld is `null` als het niet is
ingesteld; de agent houdt dan zijn eigen waarde. Zo landt een wijziging uit het
dashboard binnen één hartslag op de node.

| Veld | Betekenis |
|---|---|
| `offer_vcpu`, `offer_ram_mb`, `offer_disk_gb` | Hoeveel van de machine naar de VPS-pool gaat |
| `vmid_min`, `vmid_max` | Het VMID-blok dat van Bunk is |
| `vcpu_oversubscribe` | vCPU's per fysieke core |
| `vps_bridge`, `vps_vlan` | Waar de netwerkkaart van een nieuwe VPS aan hangt |
| `vps_gateway`, `vps_cidr_prefix` | Het VPS-netwerk zelf. De agent neemt een nieuw netwerk live over en bewaart het in `state.json`; een half of ongeldig antwoord laat het bestaande staan |

## Commando's

`GET /v1/commands` geeft een lijst (`Command`): `id`, `kind`, `vps_id` (leeg voor een
commando over de node zelf) en `payload`. Er zitten ook verzoeken voor de
webterminal tussen (`console_connect`); die zijn geen rij in de database en worden
nooit opnieuw afgeleverd.

| `kind` | Wat |
|---|---|
| `provision` | VPS aanmaken. Payload: `name`, `vcpu`, `ram_mb`, `disk_gb`, `template_id`, `cloud_init` (`user`, `password`), `ssh_keys`, `ip_config`, `rate_mbit` |
| `delete` | VM verwijderen. Payload: `vm_id`; de agent weigert als de VM bij een andere VPS hoort |
| `start`, `stop`, `pause`, `resume`, `reboot` | Aan/uit |
| `backup`, `delete_backup`, `restore_backup` | Back-ups maken, weggooien en terugzetten |
| `inventory` | Lijst van alle gasten op de node, voor het vergelijken met de administratie |
| `update` | De agent werkt zichzelf bij en herstart |
| `console_connect` | Open een webterminal naar het privé-adres van een VPS |

### Afleveren en herleveren

- Een commando gaat van `pending` naar `delivered` zodra de agent het ophaalt.
  Alleen wat werkelijk als afgeleverd gemarkeerd werd, gaat mee; een commando dat
  tussendoor geannuleerd werd, niet.
- Komt er geen resultaat, dan wordt het opnieuw uitgedeeld: na 90 seconden, en
  na 15 minuten voor `backup` en `restore_backup`. Na vijf keer nog maar eens per
  half uur, en het wordt één keer gemeld aan de operator.
- De agent voert een commando één keer uit en meldt het resultaat zo vaak als
  erom gevraagd wordt (`memo.go`). Een commando dat nog loopt, krijgt geen
  antwoord.
- Commando's voor verschillende VPS'en lopen naast elkaar (standaard vier),
  commando's voor dezelfde VPS achter elkaar.
- Bij SIGTERM haalt de agent niets nieuws meer op en krijgt lopend werk 75
  seconden om af te ronden.

### Resultaat

`POST /v1/commands/:id/result` met `CommandResult`:

| Veld | Betekenis |
|---|---|
| `status` | `done` of `failed` |
| `vm_id` | Het id van de VM op de hypervisor. Ook bij een mislukking, als de VM al bestond, zodat het control plane hem kan opruimen |
| `ip` | Gemeld adres; het control plane houdt het adres dat het zelf toekende |
| `error` | Uitleg bij `failed` |
| `volid`, `size_bytes` | Bij een back-up |
| `guests` | Bij `inventory` |

Een resultaat voor een commando dat al afgerond is, verandert niets. Uitzondering:
meldt een `provision` zich als `done` nadat hij al als mislukt was afgeschreven,
dan volgt een `delete` voor die VM.

## Port forwards

`GET /v1/port-forwards` geeft de volledige gewenste set (`public_port`,
`target_ip`, `target_port`, `protocol`). Een agent die zijn netwerk beheert, zet
dat in iptables om; anders logt hij wat er zou moeten staan. Op dit moment heeft
geen node een publiek adres, dus de set is leeg (zie
[ADR 0002](adr/0002-de-webterminal-is-de-enige-ingang.md)).

## Webterminal

Op een `console_connect` belt de agent het privé-adres van de VPS (poort 22),
alleen binnen het VPS-net van zijn node, en opent een WebSocket naar
`/v1/console-relay`. Het control plane koppelt die aan de browser van de klant.
Een sessie duurt maximaal vier uur.
