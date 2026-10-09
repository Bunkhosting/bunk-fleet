package main

import (
	"net"
	"strings"
	"testing"
)

func TestSubnetDerivesNetworkFromGateway(t *testing.T) {
	cases := []struct {
		gateway string
		prefix  int
		want    string
	}{
		{"10.10.0.1", 22, "10.10.0.0/22"},
		{"10.10.4.1", 22, "10.10.4.0/22"},
		{"10.10.252.1", 22, "10.10.252.0/22"},
		{"192.168.50.1", 24, "192.168.50.0/24"},
	}
	for _, c := range cases {
		got, err := vpsNetwork{Gateway: c.gateway, CidrPrefix: c.prefix}.subnet()
		if err != nil {
			t.Fatalf("subnet(%s/%d): %v", c.gateway, c.prefix, err)
		}
		if got.String() != c.want {
			t.Errorf("subnet(%s/%d) = %s, want %s", c.gateway, c.prefix, got, c.want)
		}
	}
}

func TestSubnetRejectsGarbage(t *testing.T) {
	// A bad gateway must stop the whole apply: putting a wrong address on the
	// bridge, or NATing a subnet that is not ours, is worse than doing nothing.
	cases := []vpsNetwork{
		{Gateway: "", CidrPrefix: 22},
		{Gateway: "not-an-ip", CidrPrefix: 22},
		{Gateway: "2001:db8::1", CidrPrefix: 64},
		{Gateway: "10.10.0.1", CidrPrefix: 0},
		{Gateway: "10.10.0.1", CidrPrefix: 33},
		{Gateway: "10.10.0.1\nPostUp = rm -rf /", CidrPrefix: 22},
	}
	for _, c := range cases {
		if _, err := c.subnet(); err == nil {
			t.Errorf("subnet(%q/%d) accepted a value it should have rejected", c.Gateway, c.CidrPrefix)
		}
	}
}

func TestUplinkFromRoutes(t *testing.T) {
	out := "default via 192.168.1.1 dev vmbr0 proto static\n"
	got, err := uplinkFromRoutes(out)
	if err != nil || got != "vmbr0" {
		t.Fatalf("uplinkFromRoutes = %q, %v; want vmbr0", got, err)
	}
}

func TestUplinkFromRoutesPrefersTheFirstDefaultRoute(t *testing.T) {
	out := "default via 10.0.0.1 dev eth0 proto dhcp metric 100\n" +
		"default via 10.0.1.1 dev eth1 proto dhcp metric 200\n"
	got, _ := uplinkFromRoutes(out)
	if got != "eth0" {
		t.Errorf("uplinkFromRoutes = %q, want eth0 (lowest metric comes first)", got)
	}
}

func TestUplinkFromRoutesWithoutADefaultRoute(t *testing.T) {
	// A node with no default route cannot give its customers internet, and
	// guessing an interface would silently NAT onto the wrong one.
	if _, err := uplinkFromRoutes("10.0.0.0/8 dev eth0 scope link\n"); err == nil {
		t.Error("uplinkFromRoutes accepted a routing table with no default route")
	}
	// The VPS subnet's own link-scope route is the dangerous near-miss: picking
	// vmbr2 here would masquerade customer traffic back onto the bridge it came
	// from instead of out of the node.
	if got, err := uplinkFromRoutes("10.10.4.0/22 dev vmbr2 proto kernel scope link src 10.10.4.1\n" +
		"default via 192.168.1.1 dev vmbr0\n"); err != nil || got != "vmbr0" {
		t.Errorf("uplinkFromRoutes = %q, %v; want vmbr0 (not the VPS bridge)", got, err)
	}
	if _, err := uplinkFromRoutes(""); err == nil {
		t.Error("uplinkFromRoutes accepted empty routing output")
	}
}

func TestNatRulesScopeEveryRuleToOurOwnSubnet(t *testing.T) {
	subnet, err := vpsNetwork{Gateway: "10.10.4.1", CidrPrefix: 22}.subnet()
	if err != nil {
		t.Fatal(err)
	}
	rules := natRules("vmbr2", "vmbr0", subnet)
	if len(rules) == 0 {
		t.Fatal("no rules generated")
	}
	for _, rule := range rules {
		joined := strings.Join(rule, " ")
		if !strings.Contains(joined, "10.10.4.0/22") {
			t.Errorf("rule does not name our subnet, so it could affect other traffic: %s", joined)
		}
		// Nothing may flush, zero or set a policy — only append scoped rules.
		for _, forbidden := range []string{"-F", "-X", "-P", "-Z"} {
			for _, arg := range rule {
				if arg == forbidden {
					t.Errorf("rule %q contains destructive flag %s", joined, forbidden)
				}
			}
		}
	}
}

func TestNatRulesAllowOutboundButNotUnsolicitedInbound(t *testing.T) {
	subnet, _ := vpsNetwork{Gateway: "10.10.4.1", CidrPrefix: 22}.subnet()
	rules := natRules("vmbr2", "vmbr0", subnet)

	var masquerade, outbound, inbound bool
	for _, rule := range rules {
		joined := strings.Join(rule, " ")
		switch {
		case strings.Contains(joined, "MASQUERADE"):
			masquerade = true
		case strings.Contains(joined, "-i vmbr2"):
			outbound = true
		case strings.Contains(joined, "-i vmbr0"):
			inbound = true
			if !strings.Contains(joined, "RELATED,ESTABLISHED") {
				t.Error("inbound rule accepts more than the return half of a customer's own connection")
			}
		}
	}
	if !masquerade || !outbound || !inbound {
		t.Errorf("missing a rule: masquerade=%v outbound=%v inbound=%v", masquerade, outbound, inbound)
	}
}

func TestCheckArgsTurnsAnAppendIntoAnExistenceCheck(t *testing.T) {
	rule := []string{"-t", "nat", "-A", "POSTROUTING", "-s", "10.10.4.0/22", "-j", "MASQUERADE"}
	got := strings.Join(checkArgs(rule), " ")
	want := "-t nat -C POSTROUTING -s 10.10.4.0/22 -j MASQUERADE"
	if got != want {
		t.Errorf("checkArgs = %q, want %q", got, want)
	}
	// The original must not be mutated: it is applied right after the check.
	if rule[2] != "-A" {
		t.Error("checkArgs mutated the rule it was given")
	}
}

func TestIfaceNameRejectsInjectionAttempts(t *testing.T) {
	for _, bad := range []string{"", "-j", "vmbr2; rm -rf /", "vmbr 2", "a/b", strings.Repeat("x", 16)} {
		if ifaceName.MatchString(bad) {
			t.Errorf("ifaceName accepted %q", bad)
		}
	}
	for _, good := range []string{"vmbr0", "eth0", "br-lan", "enp3s0", "bunk_br0"} {
		if !ifaceName.MatchString(good) {
			t.Errorf("ifaceName rejected %q", good)
		}
	}
}

// De deny-regels moeten bovenaan de chain landen, en de "bestaat hij al?"-check
// moet een check zijn en geen tweede toevoeging.
func TestDenyRulesGaanBovenaanEnZijnIdempotent(t *testing.T) {
	_, subnet, err := net.ParseCIDR("10.10.4.0/22")
	if err != nil {
		t.Fatal(err)
	}

	rules := denyRules("vmbr2", subnet)
	if len(rules) == 0 {
		t.Fatal("geen deny-regels")
	}

	for _, rule := range rules {
		joined := strings.Join(rule, " ")

		// Bovenaan invoegen, niet achteraan plakken: op een node die met een
		// oudere agent is opgezet staat de ACCEPT er al, en een deny daarachter
		// wordt nooit bereikt.
		if rule[0] != "-I" || rule[1] != "FORWARD" || rule[2] != "1" {
			t.Errorf("deny-regel wordt niet bovenaan FORWARD ingevoegd: %s", joined)
		}

		if !strings.Contains(joined, "10.10.4.0/22") {
			t.Errorf("deny-regel noemt ons subnet niet, dus hij raakt ander verkeer: %s", joined)
		}

		// De check-vorm moet een check zijn. Zou hier "-I" blijven staan, dan
		// voegt elke agentstart dezelfde regel nog een keer toe.
		check := strings.Join(checkArgs(rule), " ")
		if strings.Contains(check, "-I ") {
			t.Errorf("de check is nog steeds een insert: %s", check)
		}
		if !strings.HasPrefix(check, "-C FORWARD ") {
			t.Errorf("de check heeft niet de vorm '-C FORWARD ...': %s", check)
		}
		if strings.HasPrefix(check, "-C FORWARD 1") {
			t.Errorf("het positienummer staat nog in de check: %s", check)
		}
	}
}

func TestUitgaandeSmtpWordtGeweigerd(t *testing.T) {
	// Een VPS die zelf mail verstuurt is in de praktijk een gekaapte VPS, en de
	// rekening is dat het adres van de node op een blocklist belandt -- waarna
	// iedereen op die node nergens meer bij kan.
	_, subnet, _ := net.ParseCIDR("10.10.4.0/22")

	gevonden := map[string]bool{}
	for _, rule := range denyRules("vmbr2", subnet) {
		joined := strings.Join(rule, " ")
		for _, poort := range []string{"25", "465", "587"} {
			if strings.Contains(joined, "--dport "+poort+" ") || strings.HasSuffix(joined, "--dport "+poort) {
				gevonden[poort] = true
			}
			if strings.Contains(joined, "--dport "+poort) && strings.Contains(joined, "REJECT") {
				gevonden[poort] = true
			}
		}
	}

	for _, poort := range []string{"25", "465", "587"} {
		if !gevonden[poort] {
			t.Errorf("uitgaande poort %s wordt niet geweigerd", poort)
		}
	}
}

// Een klant mag niet bij het LAN achter de node: de router, de Proxmox-
// interface, andere machines. DNS wel, want de gast krijgt de nameserver van de
// host mee en die staat vaak op het LAN.
func TestPrivenettenDichtBehalveDNS(t *testing.T) {
	_, subnet, err := net.ParseCIDR("10.10.4.0/22")
	if err != nil {
		t.Fatal(err)
	}
	rules := denyRules("vmbr2", subnet)

	plek := func(net, actie string, dns bool) int {
		for i, r := range rules {
			j := strings.Join(r, " ")
			if strings.Contains(j, "-d "+net+" ") && strings.HasSuffix(j, "-j "+actie) &&
				strings.Contains(j, "--dport 53") == dns {
				return i
			}
		}
		return -1
	}

	for _, n := range []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"} {
		drop, dns := plek(n, "DROP", false), plek(n, "ACCEPT", true)
		if drop < 0 {
			t.Errorf("geen DROP naar %s", n)
			continue
		}
		if dns < 0 {
			t.Errorf("geen DNS-uitzondering naar %s; naamresolutie zou breken", n)
			continue
		}
		// Elke regel gaat bovenaan, dus wat later in de lijst staat, staat
		// hoger in de keten. De uitzondering moet boven de DROP komen.
		if dns < drop {
			t.Errorf("de DNS-uitzondering naar %s komt onder de DROP en wordt nooit bereikt", n)
		}
	}
}

// Op een beheerde node is de gateway de hypervisor zelf. Een VPS mocht daar
// nieuwe verbindingen openen, en bereikte zo de Proxmox-interface.
func TestHostRegelsWeigerenAlleenNieuweVerbindingen(t *testing.T) {
	_, subnet, _ := net.ParseCIDR("10.10.4.0/22")
	rules := hostRules("vmbr2", subnet)
	if len(rules) == 0 {
		t.Fatal("geen regels voor de host")
	}
	for _, r := range rules {
		j := strings.Join(r, " ")
		if r[1] != "INPUT" || !strings.Contains(j, "--ctstate NEW") || !strings.Contains(j, "10.10.4.0/22") {
			t.Errorf("hostregel raakt meer dan nieuwe verbindingen van klanten: %s", j)
		}
		if strings.Contains(strings.Join(checkArgs(r), " "), "-I ") {
			t.Errorf("de check is een insert: %s", j)
		}
	}
}
