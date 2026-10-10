package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

func subnetVan(t *testing.T, cidr string) *net.IPNet {
	t.Helper()
	_, n, err := net.ParseCIDR(cidr)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func adres(t *testing.T, cidr string) net.Addr {
	t.Helper()
	ip, n, err := net.ParseCIDR(cidr)
	if err != nil {
		t.Fatal(err)
	}
	return &net.IPNet{IP: ip, Mask: n.Mask}
}

// Het geval waar dit allemaal om begon: een bridge die bestaat, een VPS die er
// goed op hangt, en een host zonder adres op die bridge. Dat is wat er op de
// eerste eigen node stond, en het enige wat de operator zag was een terminal
// die dichtviel.
func TestEenBridgeZonderAdresInHetVpsNetwerkWordtGemeld(t *testing.T) {
	o := beoordeelNetwerk(netwerkFeiten{
		Bridge:        "vmbr2",
		BridgeBestaat: true,
		Subnet:        subnetVan(t, "172.16.22.0/24"),
		BronAdres:     net.ParseIP("192.168.1.70"),
	})

	if o.Notitie == "" {
		t.Fatal("geen melding voor een bridge zonder adres in het VPS-netwerk")
	}
	for _, moet := range []string{"vmbr2", "172.16.22.0/24", "192.168.1.70", "BUNK_MANAGE_NETWORK"} {
		if !strings.Contains(o.Notitie, moet) {
			t.Errorf("de melding noemt %q niet: %s", moet, o.Notitie)
		}
	}
	if o.Blokkerend {
		t.Error("een vermoeden hoort een node niet uit de verkoop te halen")
	}
}

// Het advies staat achteraan, en wat boven de grens van het control plane valt
// wordt afgekapt. Met de langste adressen en de langste bridgenaam moet het dus
// nog helemaal passen, anders verdwijnt precies het deel dat zegt wat te doen.
func TestDeMeldingPastInDeKolomMetDeLangsteAdressen(t *testing.T) {
	o := beoordeelNetwerk(netwerkFeiten{
		Bridge:        "vmbr1234567890", // IFNAMSIZ staat 15 tekens toe
		BridgeBestaat: true,
		Subnet:        subnetVan(t, "255.255.255.0/24"),
		// BUITEN het net, anders is er niets mis en blijft de melding leeg. Dan
		// slaagt de lengtecontrole hieronder triviaal, en dat is precies een test
		// die slaagt omdat er niets gebeurt.
		BronAdres: net.ParseIP("254.254.254.254"),
	})

	if o.Notitie == "" {
		t.Fatal("geen melding: de invoer raakt het pad niet dat deze test wil meten")
	}
	if len(o.Notitie) > 240 {
		t.Errorf("de melding is %d tekens en wordt dus afgekapt: %s", len(o.Notitie), o.Notitie)
	}
	if !strings.Contains(o.Notitie, "BUNK_MANAGE_NETWORK") || !strings.Contains(o.Notitie, "vrij adres") {
		t.Errorf("het advies ontbreekt: %s", o.Notitie)
	}
}

// Beide adviezen moeten er staan. Alleen "zet BUNK_MANAGE_NETWORK=1" is fout voor
// een node waar een router de gateway al bezit.
func TestHetAdviesNoemtOokHetGevalMetEenRouter(t *testing.T) {
	o := beoordeelNetwerk(netwerkFeiten{
		Bridge:        "vmbr2",
		BridgeBestaat: true,
		Subnet:        subnetVan(t, "172.16.22.0/24"),
		BronAdres:     net.ParseIP("192.168.1.70"),
	})

	if !strings.Contains(o.Notitie, "router") {
		t.Errorf("het advies houdt geen rekening met een bestaande router: %s", o.Notitie)
	}
	if strings.Index(o.Notitie, "vrij adres") > strings.Index(o.Notitie, "BUNK_MANAGE_NETWORK") {
		t.Errorf("het veilige advies moet voorop staan: %s", o.Notitie)
	}
}

// De tegenproef, en de belangrijkste. Het eerste node van de vloot bereikt zijn
// VPS'en via een router en heeft geen bridge ingesteld. Een controle die dat als
// storing meldt, markeert elke gezonde node op die manier -- en dat is geen
// theorie: de lhd-node werkt precies zo.
func TestEenNodeZonderBridgeDieViaEenRouterWerktKrijgtGeenAlarm(t *testing.T) {
	o := beoordeelNetwerk(netwerkFeiten{
		Bridge:    "",
		Subnet:    subnetVan(t, "10.10.0.0/22"),
		BronAdres: net.ParseIP("192.168.10.10"),
	})

	if o.Notitie != "" || o.Blokkerend {
		t.Errorf("een node zonder bridge kreeg een oordeel: %+v", o)
	}
}

func TestEenBridgeMetEenAdresInHetNetIsInOrde(t *testing.T) {
	o := beoordeelNetwerk(netwerkFeiten{
		Bridge:         "vmbr2",
		BridgeBestaat:  true,
		Subnet:         subnetVan(t, "172.16.22.0/24"),
		BridgeAdressen: []net.Addr{adres(t, "172.16.22.254/24")},
		BronAdres:      net.ParseIP("172.16.22.254"),
	})

	if o.Notitie != "" || o.Blokkerend {
		t.Errorf("een gezonde bridge kreeg een oordeel: %+v", o)
	}
}

func TestEenAdresOpEenAnderKaartjeInHetNetTeltOok(t *testing.T) {
	o := beoordeelNetwerk(netwerkFeiten{
		Bridge:        "vmbr2",
		BridgeBestaat: true,
		Subnet:        subnetVan(t, "172.16.22.0/24"),
		BronAdres:     net.ParseIP("172.16.22.5"),
	})

	if o.Notitie != "" {
		t.Errorf("een route via een ander kaartje in hetzelfde net is geen storing: %s", o.Notitie)
	}
}

func TestEenBridgeDieNietBestaatIsEenNotitieEnGeenStoring(t *testing.T) {
	o := beoordeelNetwerk(netwerkFeiten{
		Bridge: "vmbr2",
		Subnet: subnetVan(t, "172.16.22.0/24"),
	})

	if !strings.Contains(o.Notitie, "bestaat niet") {
		t.Errorf("geen uitleg dat de bridge ontbreekt: %q", o.Notitie)
	}
	if o.Blokkerend {
		t.Error("een agent buiten de host is een geldige opstelling en mag niet blokkeren")
	}
}

// Dit is het ENIGE geval dat een node uit de verkoop haalt, en het is bewust
// smal: de operator vroeg de agent het netwerk te beheren, en dat lukte niet. Dat
// is geen vermoeden maar een vaststelling van de agent zelf.
func TestEenMislukteBeheerdeOpzetBlokkeert(t *testing.T) {
	o := beoordeelNetwerk(netwerkFeiten{
		Bridge:      "vmbr2",
		Subnet:      subnetVan(t, "172.16.22.0/24"),
		Beheerd:     true,
		ToepassFout: "kan gateway-adres niet op vmbr2 zetten",
	})

	if !o.Blokkerend {
		t.Fatal("een node waarvan het beheerde netwerk mislukte blijft verkopen")
	}
	if !strings.Contains(o.Notitie, "kan gateway-adres") {
		t.Errorf("de oorzaak staat er niet bij: %q", o.Notitie)
	}
}

func TestEenMislukteOpzetBlokkeertNietAlsDeOperatorHetNietVroeg(t *testing.T) {
	// Zonder beheer is er ook niets dat de agent kon laten mislukken, en een
	// restfout uit een eerdere configuratie hoort een node niet te blokkeren.
	o := beoordeelNetwerk(netwerkFeiten{
		Subnet:      subnetVan(t, "172.16.22.0/24"),
		Beheerd:     false,
		ToepassFout: "oud",
	})

	if o.Blokkerend {
		t.Error("een onbeheerd netwerk blokkeerde op een foutmelding")
	}
}

func TestZonderToegewezenNetwerkValtErNietsTeBeoordelen(t *testing.T) {
	if o := beoordeelNetwerk(netwerkFeiten{Bridge: "vmbr2", Beheerd: true, ToepassFout: "x"}); o != (netwerkOordeel{}) {
		t.Errorf("zonder subnet kwam er toch een oordeel: %+v", o)
	}
}

func TestHetPaneelGaatVoorDeOmgevingBijDeBridge(t *testing.T) {
	paneel := "vmbr2"
	leeg := ""

	cases := []struct {
		naam       string
		omgeving   string
		instelling transport.NodeSettings
		wil        string
	}{
		{"paneel wint van omgeving", "vmbr0", transport.NodeSettings{Bridge: &paneel}, "vmbr2"},
		{"geen paneel: de omgeving", "vmbr0", transport.NodeSettings{}, "vmbr0"},
		// Een lege bridge uit het paneel betekent "neem over van de template". Dat
		// is geen keuze en mag de omgeving dus niet wegdrukken.
		{"leeg paneel is geen keuze", "vmbr0", transport.NodeSettings{Bridge: &leeg}, "vmbr0"},
		// Dit is het geval op de eerste eigen node: de bridge staat alleen in het
		// paneel. De omgeving is leeg en het netwerk werd daardoor nooit opgezet.
		{"alleen het paneel", "", transport.NodeSettings{Bridge: &paneel}, "vmbr2"},
	}
	for _, c := range cases {
		if got := effectieveBridge(c.omgeving, c.instelling); got != c.wil {
			t.Errorf("%s: %q, wilde %q", c.naam, got, c.wil)
		}
	}
}

func TestEersteGastIpSlaatDeGatewayOver(t *testing.T) {
	n := subnetVan(t, "172.16.22.0/24")

	if got := eersteGastIP(n, net.ParseIP("172.16.22.1")); got.String() != "172.16.22.2" {
		t.Errorf("kreeg %s, wilde 172.16.22.2", got)
	}
	// Staat de gateway ergens anders, dan is .1 gewoon een adres.
	if got := eersteGastIP(n, net.ParseIP("172.16.22.254")); got.String() != "172.16.22.1" {
		t.Errorf("kreeg %s, wilde 172.16.22.1", got)
	}
}

func beheerVoor(manage bool, bridge string) *netwerkBeheer {
	return nieuwNetwerkBeheer(
		config.VpsNetworkConfig{Bridge: bridge, Gateway: "172.16.22.1", CidrPrefix: 24},
		manage, persistedState{}, "")
}

// De bridge staat alleen in het paneel en het paneel antwoordt pas bij de eerste
// hartslag. Dit is het pad dat de eerste eigen node nooit kreeg.
func TestEenBridgeUitHetPaneelWordtAlsnogToegepast(t *testing.T) {
	b := beheerVoor(true, "") // omgeving leeg, zoals bij een node die via het paneel is ingericht
	paneel := "bunktest9"
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	b.bijwerken(logger, transport.NodeSettings{Bridge: &paneel})

	if !b.geprobeerd || b.toegepast != "bunktest9" {
		t.Fatalf("de bridge uit het paneel is niet toegepast: geprobeerd=%v toegepast=%q", b.geprobeerd, b.toegepast)
	}
	// Op deze machine bestaat die bridge niet, dus de poging moet mislukken --
	// en dat hoort bij de operator terecht te komen, niet in een logbestand.
	if b.fout == "" {
		t.Error("een mislukte toepassing liet geen fout achter")
	}
}

func TestEenNodeZonderBridgeAlleenInHetPaneelKrijgtGeenValsAlarmInDeEersteHartslag(t *testing.T) {
	// Tussen het opstarten en het eerste antwoord van het control plane kent de
	// agent zijn bridge nog niet. Dat mag niet als "mislukt" de deur uit gaan:
	// dan zet elke herstart een gezonde node even uit de verkoop.
	b := beheerVoor(true, "")

	if o := b.oordeel(); o.Blokkerend {
		t.Errorf("de eerste hartslag blokkeert al: %+v", o)
	}
}

func TestEenBridgeDieAlIsToegepastWordtNietElkeHartslagOpnieuwGedaan(t *testing.T) {
	b := beheerVoor(true, "")
	paneel := "bunktest9"
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	b.bijwerken(logger, transport.NodeSettings{Bridge: &paneel})
	eerste := b.laatstePog
	b.bijwerken(logger, transport.NodeSettings{Bridge: &paneel})

	if !b.laatstePog.Equal(eerste) {
		t.Error("dezelfde bridge werd bij elke hartslag opnieuw toegepast")
	}
}

func TestEenOnbeheerdeNodeOnthoudtHetPaneelWelMaarPastNietsToe(t *testing.T) {
	b := beheerVoor(false, "")
	paneel := "bunktest9"
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	b.bijwerken(logger, transport.NodeSettings{Bridge: &paneel})

	if b.geprobeerd {
		t.Error("een onbeheerde node paste toch een netwerk toe")
	}
	// Maar het oordeel moet wel op de bridge van de eigenaar gaan, anders blijft
	// een node die het netwerk niet laat beheren altijd beoordeeld op een lege
	// omgeving.
	if got := effectieveBridge(b.cfg.Bridge, b.instellingen); got != "bunktest9" {
		t.Errorf("het paneel is niet onthouden: %q", got)
	}
}

func TestEenGemisteHartslagVergeetDeBridgeVanHetPaneelNiet(t *testing.T) {
	b := beheerVoor(true, "bunkomgeving9")
	paneel := "bunktest9"
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	b.bijwerken(logger, transport.NodeSettings{Bridge: &paneel})
	eerste := b.laatstePog
	if b.toegepast != paneel {
		t.Fatalf("voorwaarde: de bridge van het paneel werd niet toegepast maar %q", b.toegepast)
	}

	b.zonderAntwoord(logger)

	if b.toegepast != paneel {
		t.Errorf("na een gemiste hartslag werd %q toegepast in plaats van de bridge van het paneel", b.toegepast)
	}
	if !b.laatstePog.Equal(eerste) {
		t.Error("een gemiste hartslag zette het netwerk opnieuw op")
	}
	if got := effectieveBridge(b.cfg.Bridge, b.instellingen); got != paneel {
		t.Errorf("het paneel is vergeten: %q", got)
	}
}

func TestZonderOoitEenAntwoordGeldtDeOmgeving(t *testing.T) {
	b := beheerVoor(true, "bunkomgeving9")
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	b.zonderAntwoord(logger)

	if b.toegepast != "bunkomgeving9" {
		t.Errorf("een node die het control plane nooit bereikte, kreeg %q in plaats van de bridge uit de omgeving", b.toegepast)
	}
}

func TestEenMislukteHartslagGaatNietNaarDeOmgeving(t *testing.T) {
	b := beheerVoor(true, "bunkomgeving9")
	paneel := "bunktest9"
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))
	b.bijwerken(logger, transport.NodeSettings{Bridge: &paneel})

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer srv.Close()
	cp := transport.New(srv.URL, nil)
	cp.SetCredentials("node-1", "token-1")

	sendHeartbeat(context.Background(), logger, stubProvider{capacity: provider.Capacity{TotalVCPU: 4, AvailVCPU: 4}}, cp, &offerHolder{v: config.OfferConfig{}}, b, nil)

	if b.toegepast != paneel {
		t.Errorf("na een 503 op de hartslag staat het netwerk op %q", b.toegepast)
	}
}

// collectMetNetwerk draait één heartbeat met een netwerkbeheerder en geeft terug
// wat er bij het control plane aankwam.
func collectMetNetwerk(t *testing.T, prov provider.Provider, nb *netwerkBeheer) *transport.Heartbeat {
	t.Helper()

	var got *transport.Heartbeat
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/heartbeat") {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		var hb transport.Heartbeat
		if err := json.NewDecoder(r.Body).Decode(&hb); err != nil {
			t.Errorf("heartbeat is geen geldige json: %v", err)
		}
		got = &hb
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	cp := transport.New(srv.URL, nil)
	cp.SetCredentials("node-1", "token-1")

	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))
	sendHeartbeat(context.Background(), logger, prov, cp, &offerHolder{v: config.OfferConfig{}}, nb, nil)
	return got
}

func TestEenMislukteBeheerdeOpzetHaaltDeNodeUitDeVerkoop(t *testing.T) {
	nb := beheerVoor(true, "vmbr2")
	nb.geprobeerd, nb.fout = true, "kan gateway-adres niet op vmbr2 zetten"

	hb := collectMetNetwerk(t, stubProvider{capacity: provider.Capacity{TotalVCPU: 4, AvailVCPU: 4}}, nb)

	if hb == nil {
		t.Fatal("geen heartbeat verstuurd")
	}
	if !strings.Contains(hb.CapacityError, "kan gateway-adres") {
		t.Errorf("de netwerkfout kwam niet als capaciteitsfout mee: %q", hb.CapacityError)
	}
	if hb.NetworkNote == "" {
		t.Error("de notitie ontbreekt naast de capaciteitsfout")
	}
}

func TestEenVermoedenBlijftEenNotitieEnHaaltDeNodeNietUitDeVerkoop(t *testing.T) {
	// Onbeheerd, en de bridge bestaat op deze machine niet: een notitie.
	nb := beheerVoor(false, "bunktest9")

	hb := collectMetNetwerk(t, stubProvider{capacity: provider.Capacity{TotalVCPU: 4, AvailVCPU: 4}}, nb)

	if hb.NetworkNote == "" {
		t.Error("geen notitie voor een bridge die niet bestaat")
	}
	if hb.CapacityError != "" {
		t.Errorf("een vermoeden werd als capaciteitsfout gemeld: %q", hb.CapacityError)
	}
	if hb.AvailVCPU != 4 {
		t.Errorf("de capaciteit ging weg door een notitie: %d", hb.AvailVCPU)
	}
}

func TestDeFoutVanDeHypervisorGaatVoorDeNetwerkfout(t *testing.T) {
	// Twee redenen in één veld is er één te veel, en de hypervisor-API is de
	// reden die er al stond.
	nb := beheerVoor(true, "vmbr2")
	nb.geprobeerd, nb.fout = true, "kan gateway-adres niet op vmbr2 zetten"

	hb := collectMetNetwerk(t, stubProvider{err: errors.New("proxmox: 401")}, nb)

	if !strings.Contains(hb.CapacityError, "401") {
		t.Errorf("de hypervisorfout werd overschreven: %q", hb.CapacityError)
	}
	if hb.NetworkNote == "" {
		t.Error("de netwerknotitie ging verloren")
	}
}

func TestEenGezondeNodeMeldtGeenNetwerknotitie(t *testing.T) {
	// Geen netwerkbeheerder (bijvoorbeeld een ESXi-node): niets te melden, en een
	// oudere control plane die het veld niet kent merkt er niets van.
	hb := collectMetNetwerk(t, stubProvider{capacity: provider.Capacity{TotalVCPU: 4}}, nil)

	if hb.NetworkNote != "" || hb.CapacityError != "" {
		t.Errorf("een node zonder netwerkbeheer meldde iets: %+v", hb)
	}
}

func ptr[T any](v T) *T { return &v }

// Eindhoven verhuisde van 172.16.22.0/24 naar 172.16.2.0/24. Het control plane
// wist het; de agent hield het net van zijn inschrijving vast en weigerde elke
// terminal naar het nieuwe net tot iemand hem herstartte.
func TestEenNieuwNetwerkUitHetControlPlaneGeldtMeteen(t *testing.T) {
	pad := filepath.Join(t.TempDir(), "state.json")
	st := persistedState{NodeID: "node-1", AgentToken: "tok", VpsGateway: "172.16.22.1", VpsCidrPrefix: 24}
	b := nieuwNetwerkBeheer(config.VpsNetworkConfig{}, false, st, pad)
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	if got := b.subnet().String(); got != "172.16.22.0/24" {
		t.Fatalf("vooraf: kreeg %s", got)
	}

	b.bijwerken(logger, transport.NodeSettings{VpsGateway: ptr("172.16.2.1"), VpsCidrPrefix: ptr(24)})

	if got := b.subnet().String(); got != "172.16.2.0/24" {
		t.Fatalf("het nieuwe net is niet overgenomen: %s", got)
	}
	if err := allowedConsoleTarget("172.16.2.20", b.subnet()); err != nil {
		t.Errorf("de console weigert een adres in het nieuwe net: %v", err)
	}
	if err := allowedConsoleTarget("172.16.22.20", b.subnet()); err == nil {
		t.Error("de console laat nog een adres in het oude net toe")
	}

	// Na een herstart begint de agent met wat er bewaard is -- en dat moet de
	// inschrijving nog bevatten, anders verliest de node zijn identiteit.
	bewaard, ok := loadState(pad)
	if !ok {
		t.Fatal("het nieuwe netwerk is niet bewaard")
	}
	if bewaard.VpsGateway != "172.16.2.1" || bewaard.VpsCidrPrefix != 24 {
		t.Errorf("bewaard netwerk: %s/%d", bewaard.VpsGateway, bewaard.VpsCidrPrefix)
	}
	if bewaard.NodeID != "node-1" || bewaard.AgentToken != "tok" {
		t.Errorf("de inschrijving ging verloren bij het bewaren: %+v", bewaard)
	}
}

// Een half of ongeldig antwoord mag een werkende node niet zijn net afnemen:
// een nil-net betekent voor de console "alles weigeren".
func TestEenOnvolledigNetwerkLaatHetBestaandeStaan(t *testing.T) {
	pad := filepath.Join(t.TempDir(), "state.json")
	st := persistedState{NodeID: "n", AgentToken: "t", VpsGateway: "10.10.0.1", VpsCidrPrefix: 22}
	b := nieuwNetwerkBeheer(config.VpsNetworkConfig{}, false, st, pad)
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	for _, s := range []transport.NodeSettings{
		{},
		{VpsGateway: ptr("172.16.2.1")},
		{VpsCidrPrefix: ptr(24)},
		{VpsGateway: ptr("geen-adres"), VpsCidrPrefix: ptr(24)},
		{VpsGateway: ptr("172.16.2.1"), VpsCidrPrefix: ptr(0)},
		{VpsGateway: ptr("172.16.2.1"), VpsCidrPrefix: ptr(33)},
	} {
		b.bijwerken(logger, s)
		if got := b.subnet().String(); got != "10.10.0.0/22" {
			t.Fatalf("na %+v: net werd %s", s, got)
		}
	}
	if _, ok := loadState(pad); ok {
		t.Error("er is iets bewaard terwijl er niets veranderde")
	}
}

// Een node die zijn netwerk laat beheren moet het nieuwe net ook opzetten, niet
// alleen kennen.
func TestEenBeheerdeNodePastEenNieuwNetwerkToe(t *testing.T) {
	b := beheerVoor(true, "bunktest9")
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))
	b.bijwerken(logger, transport.NodeSettings{})
	eerste := b.laatstePog

	// Zonder wijziging, en binnen de wachttijd: geen nieuwe poging.
	b.bijwerken(logger, transport.NodeSettings{})
	if !b.laatstePog.Equal(eerste) {
		t.Fatal("een ongewijzigd netwerk werd opnieuw toegepast")
	}

	b.laatstePog = time.Time{}
	b.bijwerken(logger, transport.NodeSettings{VpsGateway: ptr("172.16.2.1"), VpsCidrPrefix: ptr(24)})
	if b.laatstePog.IsZero() {
		t.Error("een nieuw netwerk werd niet toegepast")
	}
}
