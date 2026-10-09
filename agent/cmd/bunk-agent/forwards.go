package main

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// Customer VPSes share the node's public address and are told apart by port, so
// every VPS on this node needs a DNAT rule. The control plane owns which port
// maps where; the agent's job is to make the firewall say the same thing.
//
// The rules live in chains of our own — BUNK-DNAT, BUNK-FWD, BUNK-SNAT — hooked
// once from the built-in chains. That is what makes reconciliation safe: the
// agent flushes and rewrites only what it owns, and an operator's own rules,
// Proxmox's firewall and Docker's chains are never touched.
const (
	dnatChain = "BUNK-DNAT"
	fwdChain  = "BUNK-FWD"
	snatChain = "BUNK-SNAT"
)

// How often to ask the control plane what the forwards should be. Desired state
// rather than events, so a node that was offline, or whose rules were flushed by
// something else, converges on the next tick instead of staying wrong until
// something happens to change.
const forwardSyncInterval = 60 * time.Second

// forwardRules renders one forward into the rules that implement it.
//
// Three rules, and each is load-bearing:
//
//	DNAT     rewrites the destination so traffic arriving on the node's public
//	         port reaches the VPS.
//	FORWARD  accepts it. The masquerade rules only allow the return half of a
//	         connection a VPS opened; this is a connection someone else opened.
//	SNAT     covers hairpin — a VPS reaching a neighbour through the public
//	         address. Without it the reply goes straight back rather than through
//	         the node, and the connection hangs.
func forwardRules(f transport.PortForward, subnet *net.IPNet) [][]string {
	proto := f.Protocol
	if proto == "" {
		proto = "tcp"
	}
	pub := strconv.Itoa(f.PublicPort)
	target := net.JoinHostPort(f.TargetIP, strconv.Itoa(f.TargetPort))

	rules := [][]string{
		{"-t", "nat", "-A", dnatChain, "-p", proto, "--dport", pub, "-j", "DNAT", "--to-destination", target},
		{"-A", fwdChain, "-p", proto, "-d", f.TargetIP, "--dport", strconv.Itoa(f.TargetPort), "-j", "ACCEPT"},
	}
	if subnet != nil {
		rules = append(rules, []string{
			"-t", "nat", "-A", snatChain,
			"-s", subnet.String(), "-d", f.TargetIP,
			"-p", proto, "--dport", strconv.Itoa(f.TargetPort),
			"-j", "MASQUERADE",
		})
	}
	return rules
}

// validForward rejects anything that should not become a firewall rule. The
// control plane is trusted, but a rule built from a bad value is a hole, and a
// target outside this node's own subnet would point traffic at the operator's
// network.
func validForward(f transport.PortForward, subnet *net.IPNet) error {
	if f.PublicPort < 1 || f.PublicPort > 65535 {
		return fmt.Errorf("public port %d out of range", f.PublicPort)
	}
	if f.TargetPort < 1 || f.TargetPort > 65535 {
		return fmt.Errorf("target port %d out of range", f.TargetPort)
	}
	if f.Protocol != "" && f.Protocol != "tcp" && f.Protocol != "udp" {
		return fmt.Errorf("protocol %q is neither tcp nor udp", f.Protocol)
	}
	return allowedConsoleTarget(f.TargetIP, subnet)
}

// fingerprint is what makes "nothing changed" cheap: the rules are only rewritten
// when the desired set actually differs from the one already applied.
func fingerprint(forwards []transport.PortForward) string {
	lines := make([]string, 0, len(forwards))
	for _, f := range forwards {
		lines = append(lines, fmt.Sprintf("%s/%d>%s:%d", f.Protocol, f.PublicPort, f.TargetIP, f.TargetPort))
	}
	sort.Strings(lines)
	return strings.Join(lines, ",")
}

// syncForwards polls the control plane and keeps the firewall matching it.
func syncForwards(ctx context.Context, logger *slog.Logger, cp *transport.Client, subnet func() *net.IPNet, manage bool) {
	if !manage {
		// Still poll. An operator running their own networking has to install
		// these by hand, and telling them nothing would leave them to guess which
		// ports the control plane just promised their customers.
		logger.Info("port forwards: not managed (BUNK_MANAGE_NETWORK=0); " +
			"the forwards this node needs will be logged as they change")
	}

	applied := ""
	ticker := time.NewTicker(forwardSyncInterval)
	defer ticker.Stop()

	for {
		forwards, err := cp.PortForwards(ctx)
		// Het net hoort in de vingerafdruk: de regels beperken de bron tot dit
		// net, dus na een verhuizing moeten ze opnieuw, ook als de lijst gelijk is.
		huidig := subnet()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			logger.Warn("port forwards: cannot read desired state", "err", err)
		} else if want := fingerprint(forwards) + "|" + huidig.String(); want != applied {
			if !manage {
				describeForwards(logger, forwards)
				applied = want
			} else if err := applyForwards(ctx, logger, forwards, huidig); err != nil {
				logger.Warn("port forwards: could not apply", "err", err)
			} else {
				logger.Info("port forwards applied", "count", len(forwards))
				applied = want
			}
		}

		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// applyForwards makes our own chains say exactly what the control plane asked
// for. Flush and rewrite rather than diff: the set is small, and a rewrite
// converges from any starting state including one an operator half-edited.
func applyForwards(ctx context.Context, logger *slog.Logger, forwards []transport.PortForward, subnet *net.IPNet) error {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	for _, chain := range []struct{ table, name, parent string }{
		{"nat", dnatChain, "PREROUTING"},
		{"filter", fwdChain, "FORWARD"},
		{"nat", snatChain, "POSTROUTING"},
	} {
		if err := ensureChain(ctx, chain.table, chain.name, chain.parent); err != nil {
			return err
		}
	}

	for _, f := range forwards {
		if err := validForward(f, subnet); err != nil {
			// Skip the bad one and keep the rest: one malformed entry must not
			// cost every other customer on this node their inbound access.
			logger.Warn("port forwards: refusing one entry", "err", err, "public_port", f.PublicPort)
			continue
		}
		for _, rule := range forwardRules(f, subnet) {
			if out, err := runCmd(ctx, "iptables", rule...); err != nil {
				return fmt.Errorf("%s: %v (%s)", strings.Join(rule, " "), err, out)
			}
		}
	}
	return nil
}

// ensureChain creates our chain if it is missing, empties it, and makes sure the
// built-in chain jumps to it exactly once.
func ensureChain(ctx context.Context, table, name, parent string) error {
	args := func(rest ...string) []string {
		if table == "filter" {
			return rest
		}
		return append([]string{"-t", table}, rest...)
	}

	// -N fails when it already exists, which is the common case and not an error.
	_, _ = runCmd(ctx, "iptables", args("-N", name)...)

	if out, err := runCmd(ctx, "iptables", args("-F", name)...); err != nil {
		return fmt.Errorf("flushing %s: %v (%s)", name, err, out)
	}

	if _, err := runCmd(ctx, "iptables", args("-C", parent, "-j", name)...); err != nil {
		if out, err := runCmd(ctx, "iptables", args("-A", parent, "-j", name)...); err != nil {
			return fmt.Errorf("hooking %s into %s: %v (%s)", name, parent, err, out)
		}
	}
	return nil
}

// describeForwards prints what the node's firewall should say, for an operator
// who maintains it themselves. One line per forward, in a shape that can be read
// straight across to a rule.
func describeForwards(logger *slog.Logger, forwards []transport.PortForward) {
	if len(forwards) == 0 {
		logger.Info("port forwards: none needed on this node")
		return
	}
	logger.Info("port forwards this node needs (install them yourself)", "count", len(forwards))
	for _, f := range forwards {
		proto := f.Protocol
		if proto == "" {
			proto = "tcp"
		}
		logger.Info("  forward",
			"proto", proto,
			"public_port", f.PublicPort,
			"to", net.JoinHostPort(f.TargetIP, strconv.Itoa(f.TargetPort)))
	}
}
