# Verwerkingsregister (AVG art. 30)

**Verwerkingsverantwoordelijke:** Bunk Hosting, Nederland. KvK en contactadres
staan op https://bunkhosting.nl/voorwaarden.html.
**Bijgewerkt:** 19 september 2026. **Bron:** de code, niet de bedoeling — elke
regel hieronder is terug te vinden in `control_plane/`.

Artikel 30 verplicht dit register voor iedereen die niet-incidenteel
persoonsgegevens verwerkt; de uitzondering voor kleine organisaties geldt hier
niet, omdat verwerking de kern van de dienst is. Het hoeft niet gepubliceerd te
worden, wel overlegd op verzoek van de Autoriteit Persoonsgegevens.

> **Let op bij wijzigen.** Dit document is pas iets waard als het klopt. Wie een
> tabel, een kolom of een externe dienst toevoegt, werkt dit bij in dezelfde
> commit. Een register dat een jaar achterloopt is schadelijker dan geen
> register: het wekt de indruk dat de afweging gemaakt is.

---

## 1. Klantaccount en authenticatie

| | |
|---|---|
| **Doel** | Iemand een account geven, hem laten inloggen, en voorkomen dat een ander dat doet. |
| **Betrokkenen** | Klanten. |
| **Gegevens** | E-mailadres, naam, wachtwoordhash (pbkdf2), TOTP-geheim, passkeys (credential-id + publieke sleutel), bevestigingsmoment, rol. |
| **Grondslag** | Uitvoering van de overeenkomst (art. 6 lid 1 sub b). Voor de tweede factor en de controle op gelekte wachtwoorden: gerechtvaardigd belang (sub f) — beveiliging van het account van de klant zelf. |
| **Ontvangers** | Geen. Resend (e-mail, zie §7) ziet het adres bij het versturen van een bevestigings- of herstelmail. |
| **Buiten de EER** | Resend is gevestigd in de VS; doorgifte op basis van het EU-US Data Privacy Framework en standaardcontractbepalingen. |
| **Bewaartermijn** | Zolang het account bestaat. Daarna verwijderd, of geanonimiseerd als er administratie aan hangt die bewaard moet blijven (`Accounts.Deletion.delete_or_anonymise_user/1`): e-mailadres, naam en de losse e-mailvelden op VPS- en verbruiksrijen worden onherkenbaar gemaakt. Verlopen sessies worden elke 30 seconden opgeruimd door de `Reconciler`. |
| **Beveiliging** | Wachtwoorden als pbkdf2, nooit in leesbare vorm. TOTP-geheimen en consolesleutels versleuteld in rust. Sessietokens gehasht opgeslagen. Snelheidsbegrenzing op inloggen, registreren en de tweede factor. Een wachtwoord dat in een bekend datalek staat wordt geweigerd (§8). |
| **Bron** | De betrokkene zelf. |

## 2. Levering en beheer van een VPS

| | |
|---|---|
| **Doel** | Een virtuele machine aanmaken, starten, stoppen, herstellen en verwijderen; de klant er via de webterminal bij laten. |
| **Betrokkenen** | Klanten. |
| **Gegevens** | VPS-naam (door de klant gekozen), eigenaar-id en e-mailadres, toegewezen IP-adres, specificaties, het moment waarop afstand is gedaan van het herroepingsrecht, de publieke consolesleutel. De opdrachten aan de node (`commands.payload`) bevatten tijdelijk het e-mailadres van de eigenaar. |
| **Grondslag** | Uitvoering van de overeenkomst. |
| **Ontvangers** | De node waarop de VPS draait. Staat die node bij iemand anders dan Bunk, dan verwerkt die persoon uitsluitend voor Bunk. |
| **Buiten de EER** | Nee. Alle nodes staan in Nederland. |
| **Bewaartermijn** | Zolang de VPS bestaat. Een verwijderde VPS wordt na **30 dagen** ontdaan van alles wat naar een persoon wijst (`Fleet.Housekeeping.scrub_deleted_vpses/1`); de rij blijft bestaan voor de administratie. Opdrachten worden na **90 dagen** verwijderd (`Provisioning.CommandQueue.purge_old_commands/2`). |
| **Beveiliging** | Eigenaarschap wordt per object afgedwongen, niet per scherm. Een node kan alleen opdrachten ophalen die voor hem bestemd zijn. De gastnaam bevat een deel van de VPS-UUID zodat een node geen machine van een ander kan overnemen. |
| **Bron** | De betrokkene zelf; het IP-adres wordt door Bunk toegekend. |

## 3. Inhoud van de virtuele machine

| | |
|---|---|
| **Doel** | Geen. Bunk verwerkt deze gegevens niet; ze staan op de schijf omdat de klant ze daar zet. |
| **Betrokkenen** | De klant en iedereen over wie hij gegevens op zijn VPS zet. |
| **Gegevens** | Onbekend en bewust onbekend: bestanden, databases, logs van de klant. |
| **Rol van Bunk** | **Verwerker**, niet verantwoordelijke. De klant bepaalt wat er staat en waarvoor. Lekt dit, dan geldt art. 33 lid 2: Bunk informeert de klant onverwijld en die meldt zelf bij de AP ([datalek.md](../runbooks/datalek.md)). |
| **Grondslag** | Uitvoering van de overeenkomst met de klant; voor zijn betrokkenen is hij zelf verantwoordelijke. |
| **Toegang** | De klant. En technisch Bunk: het control plane zet bij de uitrol zijn consolesleutel in de `authorized_keys` om de webterminal te laten werken. Die toegang wordt alleen gebruikt bij een concreet vermoeden van strafbaar gebruik of een wettelijke vordering; hoe ver dan gekeken wordt staat in [abuse.md](../runbooks/abuse.md). **Elke terminalsessie wordt vastgelegd** (§5) en die lijst is opvraagbaar. |
| **Bewaartermijn** | Bepaald door de klant. Bij verwijdering wordt de machine en zijn schijf vernietigd. |

## 4. Meten en factureren

| | |
|---|---|
| **Doel** | Vaststellen wat een klant verbruikt en dat afschrijven van zijn tegoed. |
| **Betrokkenen** | Klanten. |
| **Gegevens** | E-mailadres van de eigenaar, VPS-id, seconden, vCPU/RAM/schijf, meetmoment; tegoedregels met bedrag, soort en omschrijving; opwaarderingen met bedrag, referentie en betaalkenmerk. |
| **Grondslag** | Uitvoering van de overeenkomst; voor de factuurgegevens ook een wettelijke verplichting (fiscale bewaarplicht, art. 52 AWR). |
| **Ontvangers** | Mollie voor de betaling zelf (§6). |
| **Bewaartermijn** | Factuur- en betaalgegevens **7 jaar** (fiscale bewaarplicht). Ruwe meetregels blijven aan de VPS hangen en verliezen na 30 dagen hun e-mailadres wanneer de VPS verwijderd is. |
| **Beveiliging** | Afschrijven gebeurt onder een slot per gebruiker, zodat twee gelijktijdige bestellingen niet meer kunnen opmaken dan er is. |

## 5. Terminalsessies

| | |
|---|---|
| **Doel** | Kunnen aantonen wie wanneer via de webterminal op een VPS heeft gezeten — inclusief Bunk zelf. Dit bestaat voor de klant, niet voor ons. |
| **Betrokkenen** | Klanten en medewerkers van Bunk. |
| **Gegevens** | Gebruiker-id, VPS-id, begin- en eindtijd, of het de eigenaar was of iemand van Bunk, en waarom de sessie eindigde. Geen toetsaanslagen, geen scherminhoud. |
| **Grondslag** | Gerechtvaardigd belang (art. 6 lid 1 sub f): verantwoording kunnen afleggen over een bevoegdheid die technisch niet weg te nemen is. Het belang van de klant valt samen met het doel — hij krijgt de lijst desgevraagd. |
| **Ontvangers** | Geen. |
| **Bewaartermijn** | Nog te bepalen; op dit moment onbeperkt. **Openstaand punt:** een termijn kiezen (voorstel: 24 maanden) en die in de `Reconciler` afdwingen. |
| **Beveiliging** | Geen inhoud, alleen dat er een sessie was. |

## 6. Betalingen

| | |
|---|---|
| **Doel** | Een opwaardering van het tegoed innen. |
| **Betrokkenen** | Klanten. |
| **Gegevens** | Bedrag, referentie, betaalkenmerk bij de provider, betaalmoment en wie het bevestigde. **Bunk ziet geen rekeningnummers, kaartgegevens of banklogins**; die blijven bij Mollie. |
| **Grondslag** | Uitvoering van de overeenkomst; bewaren op grond van de fiscale bewaarplicht. |
| **Ontvangers / verwerkers** | Mollie B.V., Amsterdam. |
| **Buiten de EER** | Nee. |
| **Bewaartermijn** | 7 jaar. |

## 7. E-mail

| | |
|---|---|
| **Doel** | Bevestigingsmails, wachtwoordherstel, waarschuwingen over een laag tegoed, en operationele meldingen aan Bunk zelf. |
| **Betrokkenen** | Klanten; Bunk. |
| **Gegevens** | E-mailadres en de inhoud van het bericht. |
| **Grondslag** | Uitvoering van de overeenkomst; voor operationele meldingen gerechtvaardigd belang. |
| **Ontvangers / verwerkers** | Resend (VS). |
| **Buiten de EER** | Ja; EU-US Data Privacy Framework en standaardcontractbepalingen. |
| **Bewaartermijn** | Bij de provider volgens diens termijn. Bunk bewaart de berichten zelf niet. |

## 8. Beveiliging, misbruik en botweren

| | |
|---|---|
| **Doel** | Inbraakpogingen en misbruik tegenhouden en kunnen reconstrueren. |
| **Betrokkenen** | Iedere bezoeker. |
| **Gegevens** | IP-adres (uit `CF-Connecting-IP`), opgevraagde adressen, tijdstippen, uitkomst van aanmeldpogingen. Bij registratie een Turnstile-token. Bij het kiezen van een wachtwoord gaan de **eerste vijf tekens van een SHA-1** naar de gelekte-wachtwoordendienst — nooit het wachtwoord, nooit de volledige hash, en nooit het IP van de klant (het verzoek komt van onze server). |
| **Grondslag** | Gerechtvaardigd belang (art. 6 lid 1 sub f): een dienst die openstaat voor bots is geen dienst. |
| **Ontvangers / verwerkers** | Cloudflare (tunnel, Turnstile, DNS). Have I Been Pwned ontvangt een hashvoorvoegsel dat niet naar een persoon te herleiden is. |
| **Buiten de EER** | Cloudflare: VS, met DPF en standaardcontractbepalingen. |
| **Bewaartermijn** | Toegangslogs van de edge: zolang de container draait, en niet langer dan **90 dagen**. **Openstaand punt:** dit wordt nu niet afgedwongen door een taak, alleen door rotatie. |
| **Beveiliging** | Snelheidsbegrenzing per IP; de begrenzer gebruikt het IP dat Cloudflare meestuurt en niet een kop die de bezoeker zelf kan zetten. |

## 9. Node-eigenaren

| | |
|---|---|
| **Doel** | Iemand een machine laten aanmelden waarop klant-VPSen draaien. |
| **Betrokkenen** | Node-eigenaren (nu: Bunk zelf en één betrokkene). |
| **Gegevens** | E-mailadres, node-naam, capaciteit, status, agentversie, het netwerk waarop de node VPSen plaatst. |
| **Grondslag** | Uitvoering van de overeenkomst met de node-eigenaar. |
| **Ontvangers** | Geen. |
| **Bewaartermijn** | Zolang de node aangemeld is. |
| **Openstaand punt** | Er ligt nog **geen verwerkersovereenkomst** met de node-eigenaar die geen Bunk is. Dat is het gesprek dat de juridische review als punt 18 noemt, en tot dat gevoerd is berust §2 ("verwerkt uitsluitend voor Bunk") op een afspraak die niet op papier staat. |

---

## Wat hier nog niet in staat, en waarom

- **Support-mail.** Er is nog geen ticketsysteem; vragen komen binnen op een
  mailbox en vallen daarmee onder §7.
- **Misbruikmeldingen.** Het register daarvoor staat beschreven in
  [abuse.md](../runbooks/abuse.md) maar bestaat nog niet als tabel; zolang het
  een handmatige map is valt het buiten de systemen die hier beschreven worden.
- **Analytics.** Die zijn er niet, op geen van beide domeinen. Er staat geen
  enkele tracker en er worden geen profielen opgebouwd.
