package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
)

// vpsNetwork is the addressing this node serves its customer VPSes on, as the
// control plane recorded it. The agent may have proposed it at enrollment or the
// control plane may have carved it out of the fleet supernet — either way what
// comes back is authoritative, because it is what the control plane will put in
// each VPS's cloud-init.
type vpsNetwork struct {
	Gateway    string
	CidrPrefix int
}

// ifaceName matches a Linux interface name: no shell metacharacters, no leading
// dash that a command could read as a flag, and within IFNAMSIZ.
var ifaceName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$`)

// subnet derives the network the VPSes live on from the gateway address and
// prefix — "10.10.4.1" /22 is the gateway of 10.10.4.0/22.
func (n vpsNetwork) subnet() (*net.IPNet, error) {
	if n.CidrPrefix < 1 || n.CidrPrefix > 32 {
		return nil, fmt.Errorf("netsetup: prefix /%d out of range", n.CidrPrefix)
	}
	ip := net.ParseIP(n.Gateway)
	if ip == nil || ip.To4() == nil {
		return nil, fmt.Errorf("netsetup: gateway %q is not an IPv4 address", n.Gateway)
	}
	_, ipnet, err := net.ParseCIDR(fmt.Sprintf("%s/%d", ip.To4().String(), n.CidrPrefix))
	if err != nil {
		return nil, fmt.Errorf("netsetup: %w", err)
	}
	return ipnet, nil
}

// uplinkFromRoutes picks the interface the default route leaves by, which is the
// interface customer traffic has to be NATed onto. Reads `ip route show default`
// output rather than shelling out to anything clever.
func uplinkFromRoutes(routeOutput string) (string, error) {
	for _, line := range strings.Split(routeOutput, "\n") {
		fields := strings.Fields(line)
		// Only the default route. Any other route's interface would be the wrong
		// one to masquerade onto — a link-scope route to the VPS subnet itself,
		// say, which would NAT customer traffic straight back at the bridge.
		if len(fields) == 0 || fields[0] != "default" {
			continue
		}
		for i := 1; i < len(fields)-1; i++ {
			if fields[i] == "dev" && ifaceName.MatchString(fields[i+1]) {
				return fields[i+1], nil
			}
		}
	}
	return "", fmt.Errorf("netsetup: no default route to NAT customer traffic onto")
}

// denyRules is what a customer may NOT send outward, as iptables argument
// vectors. They are INSERTED at the top of FORWARD rather than appended, and the
// reason is not style: the allow rule below is appended, so on a node that was
// set up by an older agent it already sits in the chain. A deny appended after
// it would never be reached — the rule would exist, look right in `iptables -L`,
// and do nothing.
//
// What is blocked and why:
//
//   - Outbound SMTP (25, 465, 587). A VPS that sends mail directly is, in
//     practice, a compromised VPS sending spam, and the cost lands on us: the
//     node's address ends up on a blocklist and every other customer on it stops
//     being able to reach anything. Customers who genuinely need to send mail use
//     a relay; unblocking per node is a setting we can add when someone asks,
//     which is cheaper than the reputation of an address we cannot get back.
//   - More than 60 new connections per second from one VPS. That is far above
//     normal use and squarely in port-scan and flood territory. Established
//     connections are untouched, so a busy web server is unaffected.
//
// What this deliberately does NOT do: it does not isolate customers from each
// other. VPSes share one bridge, so their traffic is switched at layer 2 and
// never reaches FORWARD. That needs per-VM filtering on the hypervisor and is a
// separate piece of work — pretending otherwise here would be worse than the gap.
func denyRules(bridge string, subnet *net.IPNet) [][]string {
	cidr := subnet.String()

	deny := [][]string{}
	for _, port := range []string{"25", "465", "587"} {
		deny = append(deny, []string{
			"-I", "FORWARD", "1", "-i", bridge, "-s", cidr,
			"-p", "tcp", "--dport", port, "-j", "REJECT",
		})
	}

	return append(deny, []string{
		"-I", "FORWARD", "1", "-i", bridge, "-s", cidr,
		"-m", "conntrack", "--ctstate", "NEW",
		"-m", "hashlimit", "--hashlimit-mode", "srcip",
		"--hashlimit-above", "60/sec", "--hashlimit-burst", "120",
		"--hashlimit-name", "bunk_out", "-j", "DROP",
	})
}

// natRules is every firewall rule this node needs for its VPS network, as
// iptables argument vectors. Outbound is allowed and masqueraded; inbound is only
// allowed as the return half of a connection a VPS opened, which is exactly the
// shared-IPv4 tier we sell. A VPS that has bought its own address gets its rules
// elsewhere; nothing here forwards unsolicited inbound traffic.
func natRules(bridge, uplink string, subnet *net.IPNet) [][]string {
	cidr := subnet.String()
	return [][]string{
		{"-t", "nat", "-A", "POSTROUTING", "-s", cidr, "-o", uplink, "-j", "MASQUERADE"},
		{"-A", "FORWARD", "-i", bridge, "-s", cidr, "-o", uplink, "-j", "ACCEPT"},
		{
			"-A", "FORWARD", "-i", uplink, "-o", bridge, "-d", cidr,
			"-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED", "-j", "ACCEPT",
		},
	}
}

// checkArgs turns an append or insert rule into the -C form that asks "is this
// already there?", so applying the same rule twice is a no-op instead of a
// duplicate.
//
// `-I CHAIN N` needs more care than `-A CHAIN`: the position number belongs to
// the insert and not to the rule, so it has to go. Zonder dat wordt de check
// zelf een `iptables -I` en voegt elke agentstart een regel toe -- een chain die
// bij elke herstart groeit tot iemand hem toevallig bekijkt.
func checkArgs(rule []string) []string {
	out := make([]string, 0, len(rule))

	for i := 0; i < len(rule); i++ {
		switch rule[i] {
		case "-A":
			out = append(out, "-C")
		case "-I":
			out = append(out, "-C")
			// De chainnaam hoort erbij; een positienummer erachter niet.
			if i+1 < len(rule) {
				out = append(out, rule[i+1])
				i++
			}
			if i+1 < len(rule) && isPositie(rule[i+1]) {
				i++
			}
		default:
			out = append(out, rule[i])
		}
	}

	return out
}

func isPositie(arg string) bool {
	if arg == "" {
		return false
	}
	for _, r := range arg {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// applyVpsNetwork brings up the node's customer network: the bridge holds the
// gateway address, forwarding is on, and customer traffic leaves NATed on this
// node's own uplink.
//
// It runs on every agent start, not once at enrollment, so a reboot or a
// hand-edited firewall heals itself. Every step is idempotent and scoped to this
// node's own bridge and subnet — no chain is ever flushed, and no rule that does
// not mention this subnet is touched.
//
// Failures are logged, not fatal. It is off unless BUNK_MANAGE_NETWORK=1: plenty
// of nodes already have a router that owns the VPS gateway — the first node in
// the fleet does — and a second machine claiming that same address would take the
// network down rather than bring it up. Taking over an operator's networking is
// something to be asked for, never assumed.
func applyVpsNetwork(logger *slog.Logger, bridge string, n vpsNetwork, manage bool) {
	if !manage {
		logger.Info("vps network: not managed (BUNK_MANAGE_NETWORK=0); configure the bridge yourself",
			"bridge", bridge, "gateway", n.Gateway, "prefix", n.CidrPrefix)
		return
	}
	if n.Gateway == "" {
		logger.Warn("vps network: control plane assigned no gateway; customer VPSes will have no network")
		return
	}
	if bridge == "" {
		logger.Warn("vps network: no bridge configured; set BUNK_VPS_BRIDGE (e.g. vmbr2) " +
			"so the agent knows which bridge to put the customer gateway on")
		return
	}
	if !ifaceName.MatchString(bridge) {
		logger.Warn("vps network: refusing to configure an implausible bridge name", "bridge", bridge)
		return
	}
	subnet, err := n.subnet()
	if err != nil {
		logger.Warn("vps network: rejecting malformed parameters from control plane", "err", err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := ensureBridge(ctx, bridge); err != nil {
		logger.Warn("vps network: cannot bring up bridge", "bridge", bridge, "err", err)
		return
	}

	addr := fmt.Sprintf("%s/%d", n.Gateway, n.CidrPrefix)
	if out, err := runCmd(ctx, "ip", "addr", "replace", addr, "dev", bridge); err != nil {
		logger.Warn("vps network: cannot set gateway address", "addr", addr, "err", err, "detail", out)
		return
	}

	if out, err := runCmd(ctx, "sysctl", "-w", "net.ipv4.ip_forward=1"); err != nil {
		logger.Warn("vps network: cannot enable IPv4 forwarding", "err", err, "detail", out)
		return
	}

	routes, err := runCmd(ctx, "ip", "-4", "route", "show", "default")
	if err != nil {
		logger.Warn("vps network: cannot read routing table", "err", err, "detail", routes)
		return
	}
	uplink, err := uplinkFromRoutes(routes)
	if err != nil {
		logger.Warn("vps network: no uplink for customer traffic", "err", err)
		return
	}

	// Eerst wat niet mag, daarna wat wel mag. De deny-regels worden bovenaan
	// ingevoegd, dus ze staan ook op een node die met een oudere agent is
	// opgezet vóór de allow-regel die daar al hangt.
	//
	// Een deny-regel die niet geplaatst kan worden is GEEN reden om te stoppen:
	// `hashlimit` zit niet in elke kernel. Dan draait de node zonder die ene
	// grens verder, en dat staat in de log -- stoppen zou een node zonder enig
	// netwerk opleveren, wat erger is dan een node zonder snelheidsgrens.
	for _, rule := range denyRules(bridge, subnet) {
		if _, err := runCmd(ctx, "iptables", checkArgs(rule)...); err == nil {
			continue // already present
		}
		if out, err := runCmd(ctx, "iptables", rule...); err != nil {
			logger.Warn("vps network: cannot install outbound restriction; the node runs without it",
				"rule", strings.Join(rule, " "), "err", err, "detail", out)
		}
	}

	for _, rule := range natRules(bridge, uplink, subnet) {
		if _, err := runCmd(ctx, "iptables", checkArgs(rule)...); err == nil {
			continue // already present
		}
		if out, err := runCmd(ctx, "iptables", rule...); err != nil {
			logger.Warn("vps network: cannot install firewall rule",
				"rule", strings.Join(rule, " "), "err", err, "detail", out)
			return
		}
	}

	logger.Info("vps network ready",
		"bridge", bridge, "gateway", addr, "subnet", subnet.String(), "uplink", uplink)
}

// ensureBridge brings up a bridge that already exists. It deliberately does NOT
// create one: a bridge the hypervisor does not know about is invisible in the
// Proxmox UI and gone after a reboot, and — worse — creating one on a machine
// that merely *talks to* the hypervisor would make that machine believe the VPS
// subnet is directly attached, blackholing the traffic it used to route.
// The operator creates the bridge; the agent only addresses it.
func ensureBridge(ctx context.Context, bridge string) error {
	if _, err := runCmd(ctx, "ip", "link", "show", bridge); err != nil {
		return fmt.Errorf("bridge %s does not exist on this machine — create it on the "+
			"hypervisor host first (Proxmox: Datacenter > Node > Network > Create > Linux Bridge)", bridge)
	}
	if out, err := runCmd(ctx, "ip", "link", "set", bridge, "up"); err != nil {
		return fmt.Errorf("bringing bridge up: %v (%s)", err, out)
	}
	return nil
}

// runCmd executes a command and returns its combined output, which is what the
// warnings above quote when a step fails — iptables and ip both explain
// themselves on stderr.
func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// vpsNetwerkVan beantwoordt de vraag "wat is het VPS-netwerk van deze node", en
// is de enige plek waar dat antwoord vandaan komt.
//
// Het stond op twee plekken, met twee verschillende antwoorden. De
// consolecontrole viel terug van de opgeslagen staat op de eigen configuratie;
// het instellen van de bridge keek alleen naar de staat. Op een node waar
// state.json die gegevens niet heeft -- een inschrijving van voor het control
// plane ze terugstuurde, of een agent die opnieuw is opgezet -- dacht de console
// dus dat het netwerk bestond terwijl de bridge nooit was ingericht. Twee
// functies die dezelfde vraag anders beantwoorden is precies het soort verschil
// dat pas opvalt als er iemand niet bij zijn machine kan.
//
// De volgorde is niet willekeurig: wat het control plane bij de inschrijving
// terugstuurde wint van wat er lokaal is ingetypt. Het CP deelt de blokken uit
// en weet dus of jouw wens is gehonoreerd of dat je iets anders hebt gekregen.
func vpsNetwerkVan(st persistedState, cfg config.VpsNetworkConfig) vpsNetwork {
	for _, kandidaat := range []vpsNetwork{
		{Gateway: st.VpsGateway, CidrPrefix: st.VpsCidrPrefix},
		{Gateway: cfg.Gateway, CidrPrefix: cfg.CidrPrefix},
	} {
		if kandidaat.Gateway != "" && kandidaat.CidrPrefix > 0 {
			return kandidaat
		}
	}
	return vpsNetwork{}
}
