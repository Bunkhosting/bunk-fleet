package main

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
)

func mustSubnet(t *testing.T, gateway string, prefix int) *net.IPNet {
	t.Helper()
	subnet, err := vpsNetwork{Gateway: gateway, CidrPrefix: prefix}.subnet()
	if err != nil {
		t.Fatal(err)
	}
	return subnet
}

func TestAllowedConsoleTargetAcceptsAVpsOnOurOwnSubnet(t *testing.T) {
	subnet := mustSubnet(t, "10.10.4.1", 22)
	for _, host := range []string{"10.10.4.20", "10.10.5.1", "10.10.7.254"} {
		if err := allowedConsoleTarget(host, subnet); err != nil {
			t.Errorf("allowedConsoleTarget(%s) = %v, want nil", host, err)
		}
	}
}

func TestAllowedConsoleTargetRefusesOutsideOurSubnet(t *testing.T) {
	// The control plane names the target, so a bug or a compromised control
	// plane must not be able to walk the operator's LAN through our agent.
	subnet := mustSubnet(t, "10.10.4.1", 22)
	for _, host := range []string{"10.10.0.21", "192.168.1.70", "10.10.8.1"} {
		if err := allowedConsoleTarget(host, subnet); err == nil {
			t.Errorf("allowedConsoleTarget(%s) accepted an address outside %s", host, subnet)
		}
	}
}

func TestAllowedConsoleTargetRefusesDangerousAddressesEvenWithoutASubnet(t *testing.T) {
	cases := map[string]string{
		"169.254.169.254": "cloud metadata endpoint — credentials on a rented node",
		"127.0.0.1":       "loopback — the agent's own services",
		"::1":             "loopback",
		"8.8.8.8":         "public internet — would make the node an open proxy",
		"0.0.0.0":         "unspecified",
		"224.0.0.1":       "multicast",
		"fe80::1":         "link-local",
		"example.com":     "hostname — DNS would decide the target after the check",
		"":                "empty",
	}
	for host, why := range cases {
		if err := allowedConsoleTarget(host, nil); err == nil {
			t.Errorf("allowedConsoleTarget(%q) accepted it (%s)", host, why)
		}
	}
}

func TestAllowedConsoleTargetAcceptsPrivateAddressesWithoutASubnet(t *testing.T) {
	// A node that enrolled before the control plane sent its network back still
	// has to be able to serve a console.
	for _, host := range []string{"10.10.0.21", "192.168.1.50", "172.16.3.4"} {
		if err := allowedConsoleTarget(host, nil); err != nil {
			t.Errorf("allowedConsoleTarget(%s, nil) = %v, want nil", host, err)
		}
	}
}

func TestAssignedSubnetPrefersEnrolmentOverEnvironment(t *testing.T) {
	st := persistedState{VpsGateway: "10.10.4.1", VpsCidrPrefix: 22}
	cfg := config.VpsNetworkConfig{Gateway: "192.168.50.1", CidrPrefix: 24}

	got := assignedSubnet(st, cfg)
	if got == nil || got.String() != "10.10.4.0/22" {
		t.Fatalf("assignedSubnet = %v, want 10.10.4.0/22", got)
	}
}

func TestAssignedSubnetFallsBackToTheDeclaredNetwork(t *testing.T) {
	cfg := config.VpsNetworkConfig{Gateway: "192.168.50.1", CidrPrefix: 24}

	got := assignedSubnet(persistedState{}, cfg)
	if got == nil || got.String() != "192.168.50.0/24" {
		t.Fatalf("assignedSubnet = %v, want 192.168.50.0/24", got)
	}
}

func TestAssignedSubnetIsNilWhenNothingIsKnown(t *testing.T) {
	if got := assignedSubnet(persistedState{}, config.VpsNetworkConfig{}); got != nil {
		t.Fatalf("assignedSubnet = %v, want nil", got)
	}
	// A malformed value must not be treated as a subnet either.
	bad := persistedState{VpsGateway: "nonsense", VpsCidrPrefix: 22}
	if got := assignedSubnet(bad, config.VpsNetworkConfig{}); got != nil {
		t.Fatalf("assignedSubnet(malformed) = %v, want nil", got)
	}
}

// De sessielimiet moet iets betekenen. io.Copy kijkt nergens naar en blokkeert
// tot de verbinding eronder dichtgaat, dus zonder een select op de context liep
// de limiet af zonder gevolg en bleef een sessie openstaan zolang de
// TCP-verbinding bleef staan. Een dichtgeklapte laptop stuurt geen FIN: dat is
// de normale manier waarop een sessie blijft hangen.
func TestPipeStoptOpDeContext(t *testing.T) {
	a1, _ := net.Pipe()
	b1, _ := net.Pipe()
	defer a1.Close()
	defer b1.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	klaar := make(chan bool, 1)
	go func() { klaar <- pipe(ctx, a1, b1) }()

	select {
	case doorTijd := <-klaar:
		if !doorTijd {
			t.Error("pipe stopte, maar meldde niet dat het door de tijdslimiet kwam")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("pipe bleef hangen terwijl de context al lang verlopen was")
	}
}

func TestPipeStoptAlsEenKantSluit(t *testing.T) {
	// Het gewone geval: de browser gaat weg, de sessie hoort meteen te eindigen
	// en niet pas na vier uur.
	a1, a2 := net.Pipe()
	b1, _ := net.Pipe()
	defer b1.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	klaar := make(chan bool, 1)
	go func() { klaar <- pipe(ctx, a1, b1) }()

	a2.Close()

	select {
	case doorTijd := <-klaar:
		if doorTijd {
			t.Error("pipe meldde een tijdslimiet terwijl een kant gewoon sloot")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("pipe merkte niet dat een kant sloot")
	}
}

// Het instellen van de bridge en de consolecontrole moeten hetzelfde netwerk
// zien. Toen dat niet zo was, keek de console ook naar agent.env en het
// instellen alleen naar state.json -- met als gevolg dat de console een adres
// goedkeurde op een bridge die nooit was ingericht.
func TestZelfdeNetwerkVoorBridgeEnConsole(t *testing.T) {
	gevallen := []struct {
		naam string
		st   persistedState
		cfg  config.VpsNetworkConfig
	}{
		{"alleen uit de opgeslagen staat",
			persistedState{VpsGateway: "10.10.4.1", VpsCidrPrefix: 22},
			config.VpsNetworkConfig{}},
		{"alleen uit de eigen configuratie",
			persistedState{},
			config.VpsNetworkConfig{Gateway: "192.168.50.1", CidrPrefix: 24}},
		{"allebei: de staat wint",
			persistedState{VpsGateway: "10.10.4.1", VpsCidrPrefix: 22},
			config.VpsNetworkConfig{Gateway: "192.168.50.1", CidrPrefix: 24}},
		{"geen van beide", persistedState{}, config.VpsNetworkConfig{}},
	}

	for _, g := range gevallen {
		t.Run(g.naam, func(t *testing.T) {
			netwerk := vpsNetwerkVan(g.st, g.cfg)
			subnet := assignedSubnet(g.st, g.cfg)

			if netwerk.Gateway == "" {
				if subnet != nil {
					t.Fatalf("geen netwerk, maar de console kreeg %v", subnet)
				}
				return
			}
			if subnet == nil {
				t.Fatalf("netwerk %v, maar de console kreeg niets", netwerk)
			}
			if !subnet.Contains(net.ParseIP(netwerk.Gateway)) {
				t.Fatalf("de console kreeg %v, dat past niet bij gateway %s",
					subnet, netwerk.Gateway)
			}
		})
	}
}

// De gateway die het control plane bij de inschrijving terugstuurde wint van
// wat er lokaal is ingetypt: het CP deelt de blokken uit en weet dus of de wens
// van de operator is gehonoreerd.
func TestOpgeslagenStaatWintVanConfiguratie(t *testing.T) {
	netwerk := vpsNetwerkVan(
		persistedState{VpsGateway: "10.10.4.1", VpsCidrPrefix: 22},
		config.VpsNetworkConfig{Gateway: "192.168.50.1", CidrPrefix: 24},
	)

	if netwerk.Gateway != "10.10.4.1" {
		t.Fatalf("gateway = %s, wil 10.10.4.1", netwerk.Gateway)
	}
}
