package main

import (
	"fmt"
	"log/slog"
	"net"
	"sync"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// Dit bestand beantwoordt één vraag die tot nu toe nergens werd beantwoord:
// kan deze machine bij de VPS'en die hij zelf draait?
//
// De webterminal is de enige ingang tot een VPS, en hij loopt via de agent: die
// belt de VPS op zijn privé-adres. Een node die dat niet kan, ziet er van buiten
// volkomen gezond uit -- hartslag, capaciteit, API-rechten, alles klopt -- en
// verkoopt machines waar de klant niet in komt. `applyVpsNetwork` wist wél dat
// er iets mis was, maar zei dat alleen in een logbestand op de node.

// netwerkFeiten is alles wat nodig is om daarover te oordelen. Het is een
// struct met gewone waarden, zodat het oordeel te testen is zonder een echte
// interface, een echte route of een echte machine.
type netwerkFeiten struct {
	// Bridge is de effectieve bridge: wat in het paneel staat gaat voor wat in
	// de omgeving staat. Leeg betekent nergens ingesteld.
	Bridge        string
	BridgeBestaat bool
	// Subnet is het VPS-netwerk zoals het control plane het toewees; nil als er
	// geen is, en dan valt er niets te beoordelen.
	Subnet         *net.IPNet
	BridgeAdressen []net.Addr
	// BronAdres is het adres dat de kernel zou gebruiken om dat net te bereiken.
	// Nil als dat niet te bepalen was.
	BronAdres net.IP
	// Beheerd: de operator heeft de agent gevraagd dit netwerk zelf op te zetten.
	Beheerd bool
	// ToepassFout is waarom dat opzetten niet lukte; leeg als het lukte of als
	// de agent het niet hoefde te doen.
	ToepassFout string
}

// netwerkOordeel is wat het paneel te zien krijgt.
type netwerkOordeel struct {
	// Notitie is een feit dat een operator wil weten. Leeg als er niets te
	// melden valt.
	Notitie string
	// Blokkerend betekent dat deze node geen nieuwe VPS'en moet krijgen.
	Blokkerend bool
}

// beoordeelNetwerk is met opzet voorzichtig over wat het blokkeert.
//
// Alleen het geval dat de agent ZELF vaststelt -- de operator vroeg hem het
// netwerk te beheren en dat mislukte -- haalt een node uit de verkoop. Al het
// andere is een vermoeden en blijft een notitie: een bridge zonder adres kan een
// kapotte node zijn, maar ook een node waar een router het VPS-netwerk bezit en
// de agent er netjes via een route bij komt. Dat tweede is precies hoe het
// eerste node van de vloot werkt. Een vals alarm dat een gezonde node dichtzet
// kost omzet; een notitie die er ten onrechte staat kost een regel in het paneel.
func beoordeelNetwerk(f netwerkFeiten) netwerkOordeel {
	if f.Subnet == nil {
		return netwerkOordeel{}
	}

	if f.Beheerd && f.ToepassFout != "" {
		return netwerkOordeel{
			Notitie:    "VPS-netwerk niet opgezet: " + f.ToepassFout,
			Blokkerend: true,
		}
	}

	// Zonder bridge valt er niets van de host te vergelijken. Een node zonder
	// bridge werkt prima als het VPS-netwerk via een router bereikbaar is, dus
	// hier iets van zeggen zou elke node op die manier valselijk aanmerken.
	if f.Bridge == "" {
		return netwerkOordeel{}
	}

	if !f.BridgeBestaat {
		return netwerkOordeel{Notitie: fmt.Sprintf(
			"bridge %s bestaat niet op deze machine; de agent draait dus niet op de hypervisor-host zelf "+
				"en bereikt VPS'en alleen via een route", f.Bridge)}
	}

	if heeftAdresIn(f.BridgeAdressen, f.Subnet) {
		return netwerkOordeel{}
	}
	// Een ander netwerkkaartje met een adres in dit net doet hetzelfde werk als
	// een adres op de bridge.
	if f.BronAdres != nil && f.Subnet.Contains(f.BronAdres) {
		return netwerkOordeel{}
	}

	route := "geen route bepaald"
	if f.BronAdres != nil {
		route = "route via " + f.BronAdres.String()
	}

	// Het advies hangt af van wie de gateway van dit net is, en dat weet de agent
	// niet. Staat er al een router op dat adres -- en dat is geen uitzondering:
	// het eerste node van de vloot werkt zo -- dan maakt BUNK_MANAGE_NETWORK=1 er
	// twee machines van met hetzelfde adres, en daar waarschuwt de code zelf voor.
	// Een vrij adres voor de host breekt niets, dus dat staat voorop.
	//
	// Binnen 240 tekens, met de langste adressen erin. Wat daarboven valt wordt
	// afgekapt, en het advies staat achteraan.
	return netwerkOordeel{Notitie: fmt.Sprintf(
		"bridge %s heeft geen adres in %s (%s): de agent bereikt VPS'en niet. "+
			"Bezit al een router de gateway? Geef de bridge dan een vrij adres in dit net. Anders: BUNK_MANAGE_NETWORK=1.",
		f.Bridge, f.Subnet, route)}
}

func heeftAdresIn(adressen []net.Addr, subnet *net.IPNet) bool {
	for _, a := range adressen {
		var ip net.IP
		switch v := a.(type) {
		case *net.IPNet:
			ip = v.IP
		case *net.IPAddr:
			ip = v.IP
		}
		if ip != nil && ip.To4() != nil && subnet.Contains(ip) {
			return true
		}
	}
	return false
}

// effectieveBridge kiest welke bridge de host-netwerkstap gebruikt.
//
// Er waren twee bronnen voor "welke bridge" en ze werden voor verschillende
// dingen gelezen. Wat de eigenaar in het paneel zet ging naar de NIC van elke
// nieuwe VPS -- dat werkte, want daar werd hij uitgelezen. De stap die het
// gateway-adres op de host zet las alleen de omgevingsvariabele, en die staat op
// een node die via het paneel is ingericht leeg. Resultaat: VPS'en op de
// goede bridge, een host zonder adres op die bridge, en een agent die dat
// alleen in zijn logboek meldde.
//
// Het paneel gaat voor, om dezelfde reden als bij het VPS-netwerk zelf: daar kijkt
// de eigenaar naar. Een lege waarde uit het paneel betekent "neem over van de
// template" en wordt dus niet als keuze gelezen; alleen een gevulde bridge wint.
func effectieveBridge(omgeving string, s transport.NodeSettings) string {
	if s.Bridge != nil && *s.Bridge != "" {
		return *s.Bridge
	}
	return omgeving
}

// eersteGastIP geeft een adres in het VPS-netwerk dat niet de gateway is. Het
// wordt nooit aangeroepen -- alleen gebruikt om de kernel te vragen welke route
// hij voor dit net zou kiezen.
func eersteGastIP(subnet *net.IPNet, gateway net.IP) net.IP {
	basis := subnet.IP.To4()
	if basis == nil {
		return nil
	}
	for opgeteld := 1; opgeteld <= 3; opgeteld++ {
		ip := make(net.IP, 4)
		copy(ip, basis)
		ip[3] += byte(opgeteld)
		if !subnet.Contains(ip) {
			continue
		}
		if gateway != nil && ip.Equal(gateway) {
			continue
		}
		return ip
	}
	return nil
}

// bronAdresNaar vraagt de kernel via welk eigen adres dit doel bereikt zou
// worden. Een UDP-"verbinding" stuurt niets: er wordt alleen een route gekozen.
func bronAdresNaar(doel net.IP) net.IP {
	if doel == nil {
		return nil
	}
	c, err := net.DialTimeout("udp", net.JoinHostPort(doel.String(), "9"), time.Second)
	if err != nil {
		return nil
	}
	defer c.Close()
	if a, ok := c.LocalAddr().(*net.UDPAddr); ok {
		return a.IP
	}
	return nil
}

// netwerkBeheer past het VPS-netwerk toe en houdt bij wat daar van terechtkwam.
type netwerkBeheer struct {
	cfg      config.VpsNetworkConfig
	manage   bool
	statePad string // waar een nieuw netwerk wordt bewaard; leeg = niet bewaren

	mu           sync.Mutex
	state        persistedState         // bevat het netwerk, dat live kan veranderen
	instellingen transport.NodeSettings // wat het control plane het laatst stuurde
	geprobeerd   bool
	toegepast    string // de bridge waarvoor het laatst een poging is gedaan
	fout         string
	laatstePog   time.Time
}

// hoe lang er tussen twee pogingen zit als de vorige mislukte. Elke poging is
// een handvol idempotente iptables-controles, maar een mislukking logt een
// waarschuwing en dat elke dertig seconden doen zou de log vullen met één regel.
const herhaalNetwerkNa = 5 * time.Minute

func nieuwNetwerkBeheer(cfg config.VpsNetworkConfig, manage bool, st persistedState, statePad string) *netwerkBeheer {
	return &netwerkBeheer{cfg: cfg, manage: manage, state: st, statePad: statePad}
}

// subnet is het VPS-net van dit moment. De console en de port-forwards vragen
// het bij elk gebruik opnieuw, in plaats van één keer bij het opstarten: een
// node die naar een ander net verhuist, moet niet tot de volgende herstart elke
// terminal weigeren.
func (b *netwerkBeheer) subnet() *net.IPNet {
	if b == nil {
		return nil
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	return assignedSubnet(b.state, b.cfg)
}

// neemNetwerkOver verwerkt het netwerk dat het control plane meestuurt. Het
// geeft true terug als het anders is dan wat de agent had.
//
// Alleen een volledig en geldig netwerk telt. Een half antwoord, of een
// gateway die geen IPv4-adres is, zou de console op nil zetten -- en nil
// betekent daar "alles weigeren" voor een node die gewoon werkte.
//
// Het nieuwe netwerk gaat naar state.json, want daar begint de agent na een
// herstart mee. Lukt dat schrijven niet, dan geldt het toch tot de herstart, en
// stuurt het control plane het daarna opnieuw.
func (b *netwerkBeheer) neemNetwerkOver(logger *slog.Logger, s transport.NodeSettings) bool {
	if s.VpsGateway == nil || s.VpsCidrPrefix == nil {
		return false
	}
	nieuw := vpsNetwork{Gateway: *s.VpsGateway, CidrPrefix: *s.VpsCidrPrefix}
	if _, err := nieuw.subnet(); err != nil {
		logger.Warn("vps network: ongeldig netwerk van het control plane genegeerd", "err", err)
		return false
	}
	if b.state.VpsGateway == nieuw.Gateway && b.state.VpsCidrPrefix == nieuw.CidrPrefix {
		return false
	}

	logger.Info("vps network: nieuw netwerk van het control plane",
		"van", fmt.Sprintf("%s/%d", b.state.VpsGateway, b.state.VpsCidrPrefix),
		"naar", fmt.Sprintf("%s/%d", nieuw.Gateway, nieuw.CidrPrefix))
	b.state.VpsGateway = nieuw.Gateway
	b.state.VpsCidrPrefix = nieuw.CidrPrefix
	if b.statePad != "" {
		if err := saveState(b.statePad, b.state); err != nil {
			logger.Warn("vps network: kon het nieuwe netwerk niet bewaren; het geldt tot de volgende herstart", "err", err)
		}
	}
	return true
}

// pasToe zet het netwerk op voor `bridge`, als de operator daarom heeft gevraagd.
func (b *netwerkBeheer) pasToe(logger *slog.Logger, bridge string) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.geprobeerd = true
	b.toegepast = bridge
	b.laatstePog = time.Now()
	b.fout = ""

	if err := applyVpsNetwork(logger, bridge, vpsNetwerkVan(b.state, b.cfg), b.manage); err != nil {
		b.fout = err.Error()
	}
}

// bijwerken is wat de hartslaglus na elk antwoord van het control plane doet.
//
// Hij onthoudt altijd wat het paneel zegt, want ook een node die zijn netwerk
// niet laat beheren, wordt beoordeeld op de bridge die de eigenaar koos. Alleen
// als de operator om beheer vroeg wordt er iets toegepast: opnieuw als de bridge
// is gewijzigd -- iets wat de eigenaar in het paneel doet nadat de agent allang
// draait -- of als de vorige poging mislukte en het tijd is voor een nieuwe.
func (b *netwerkBeheer) bijwerken(logger *slog.Logger, s transport.NodeSettings) {
	if b == nil {
		return
	}
	b.mu.Lock()
	b.instellingen = s
	netwerkAnders := b.neemNetwerkOver(logger, s)
	bridge := effectieveBridge(b.cfg.Bridge, s)
	gewijzigd := !b.geprobeerd || bridge != b.toegepast || netwerkAnders
	opnieuw := b.fout != "" && time.Since(b.laatstePog) >= herhaalNetwerkNa
	b.mu.Unlock()

	if !b.manage {
		return
	}
	if gewijzigd || opnieuw {
		if gewijzigd {
			logger.Info("vps network: bridge wordt toegepast", "bridge", bridge)
		}
		b.pasToe(logger, bridge)
	}
}

// zonderAntwoord is wat de hartslaglus doet als het control plane niet
// antwoordde. Het netwerk krijgt dan een kans met de laatst bekende
// instellingen: bij de eerste hartslag na het opstarten zijn dat er geen en
// geldt de omgeving, zodat een node die het dashboard nooit bereikt toch
// netwerk heeft.
//
// Het was een lege set instellingen. Dan telde één gemiste hartslag als "de
// eigenaar heeft de bridge weggehaald": de agent viel terug op de bridge uit de
// omgeving, zette daar de gateway en de regels op (of meldde de node uit de
// verkoop als die leeg was), en zette het bij het volgende antwoord weer terug
// -- met het gateway-adres achtergebleven op de verkeerde bridge.
func (b *netwerkBeheer) zonderAntwoord(logger *slog.Logger) {
	if b == nil {
		return
	}
	b.mu.Lock()
	laatste := b.instellingen
	b.mu.Unlock()
	b.bijwerken(logger, laatste)
}

// oordeel verzamelt de feiten van dit moment en beoordeelt ze. Het draait elke
// hartslag, zodat een notitie vanzelf verdwijnt zodra de operator iets heeft
// rechtgezet in plaats van tot de volgende herstart te blijven staan.
func (b *netwerkBeheer) oordeel() netwerkOordeel {
	if b == nil {
		return netwerkOordeel{}
	}
	b.mu.Lock()
	n := vpsNetwerkVan(b.state, b.cfg)
	fout := b.fout
	s := b.instellingen
	b.mu.Unlock()

	subnet, err := n.subnet()
	if err != nil {
		return netwerkOordeel{}
	}

	f := netwerkFeiten{
		Bridge:      effectieveBridge(b.cfg.Bridge, s),
		Subnet:      subnet,
		Beheerd:     b.manage,
		ToepassFout: fout,
	}
	if f.Bridge != "" && ifaceName.MatchString(f.Bridge) {
		if iface, err := net.InterfaceByName(f.Bridge); err == nil {
			f.BridgeBestaat = true
			f.BridgeAdressen, _ = iface.Addrs()
		}
	}
	f.BronAdres = bronAdresNaar(eersteGastIP(subnet, net.ParseIP(n.Gateway)))

	return beoordeelNetwerk(f)
}
