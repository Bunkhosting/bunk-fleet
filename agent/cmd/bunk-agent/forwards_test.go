package main

import (
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

func sshForward() transport.PortForward {
	return transport.PortForward{
		PublicPort: 20001,
		TargetIP:   "10.10.4.20",
		TargetPort: 22,
		Protocol:   "tcp",
	}
}

func TestForwardRulesCoverTheThreeThingsAForwardNeeds(t *testing.T) {
	subnet := mustSubnet(t, "10.10.4.1", 22)
	rules := forwardRules(sshForward(), subnet)

	var dnat, accept, hairpin bool
	for _, rule := range rules {
		joined := strings.Join(rule, " ")
		switch {
		case strings.Contains(joined, "DNAT"):
			dnat = true
			if !strings.Contains(joined, "--to-destination 10.10.4.20:22") {
				t.Errorf("DNAT does not point at the VPS: %s", joined)
			}
			if !strings.Contains(joined, "--dport 20001") {
				t.Errorf("DNAT does not match the public port: %s", joined)
			}
		case strings.Contains(joined, "ACCEPT"):
			// The masquerade rules only allow the return half of a connection a
			// VPS opened. An inbound connection is somebody else's.
			accept = true
		case strings.Contains(joined, "MASQUERADE"):
			hairpin = true
			if !strings.Contains(joined, "-s 10.10.4.0/22") {
				t.Errorf("hairpin rule is not scoped to our own subnet: %s", joined)
			}
		}
	}
	if !dnat || !accept || !hairpin {
		t.Errorf("missing a rule: dnat=%v accept=%v hairpin=%v", dnat, accept, hairpin)
	}
}

func TestForwardRulesOnlyTouchOurOwnChains(t *testing.T) {
	// Everything the agent writes has to be reversible by flushing chains it
	// owns. A rule appended straight to PREROUTING or FORWARD would survive a
	// reconcile and accumulate.
	subnet := mustSubnet(t, "10.10.4.1", 22)
	for _, rule := range forwardRules(sshForward(), subnet) {
		joined := strings.Join(rule, " ")
		for _, builtin := range []string{"-A PREROUTING", "-A POSTROUTING", "-A FORWARD", "-A INPUT", "-A OUTPUT"} {
			if strings.Contains(joined, builtin) {
				t.Errorf("rule writes straight into a built-in chain: %s", joined)
			}
		}
		if !strings.Contains(joined, "BUNK-") {
			t.Errorf("rule does not name one of our chains: %s", joined)
		}
	}
}

func TestForwardRulesWithoutAKnownSubnetSkipHairpin(t *testing.T) {
	// A node that has not been told its subnet still gets working inbound; it
	// only loses VPS-to-VPS-via-public-address, which is the rarer case.
	rules := forwardRules(sshForward(), nil)
	for _, rule := range rules {
		if strings.Contains(strings.Join(rule, " "), "MASQUERADE") {
			t.Error("emitted a hairpin rule with no subnet to scope it to")
		}
	}
	if len(rules) != 2 {
		t.Errorf("got %d rules, want 2 (dnat + accept)", len(rules))
	}
}

func TestForwardRulesDefaultToTcp(t *testing.T) {
	f := sshForward()
	f.Protocol = ""
	for _, rule := range forwardRules(f, nil) {
		if !strings.Contains(strings.Join(rule, " "), "-p tcp") {
			t.Errorf("rule has no protocol: %s", strings.Join(rule, " "))
		}
	}
}

func TestValidForwardRefusesWhatWouldBeAHole(t *testing.T) {
	subnet := mustSubnet(t, "10.10.4.1", 22)
	base := sshForward()

	cases := map[string]transport.PortForward{
		"port 0":              {PublicPort: 0, TargetIP: base.TargetIP, TargetPort: 22},
		"port above range":    {PublicPort: 70000, TargetIP: base.TargetIP, TargetPort: 22},
		"target port 0":       {PublicPort: 20001, TargetIP: base.TargetIP, TargetPort: 0},
		"odd protocol":        {PublicPort: 20001, TargetIP: base.TargetIP, TargetPort: 22, Protocol: "icmp"},
		"target off-subnet":   {PublicPort: 20001, TargetIP: "192.168.1.70", TargetPort: 22},
		"target on the host":  {PublicPort: 20001, TargetIP: "127.0.0.1", TargetPort: 22},
		"target is metadata":  {PublicPort: 20001, TargetIP: "169.254.169.254", TargetPort: 80},
		"target is a name":    {PublicPort: 20001, TargetIP: "evil.example.com", TargetPort: 22},
		"target is public ip": {PublicPort: 20001, TargetIP: "8.8.8.8", TargetPort: 53},
	}
	for name, f := range cases {
		if err := validForward(f, subnet); err == nil {
			t.Errorf("validForward accepted %s", name)
		}
	}

	if err := validForward(base, subnet); err != nil {
		t.Errorf("validForward rejected a good forward: %v", err)
	}
}

func TestFingerprintIgnoresOrderButNotContent(t *testing.T) {
	// The rules are only rewritten when the desired set actually changed; an
	// ordering difference from the API must not cause a rewrite every minute,
	// and a real change must not be missed.
	a := transport.PortForward{PublicPort: 20001, TargetIP: "10.10.4.20", TargetPort: 22, Protocol: "tcp"}
	b := transport.PortForward{PublicPort: 20002, TargetIP: "10.10.4.21", TargetPort: 22, Protocol: "tcp"}

	if fingerprint([]transport.PortForward{a, b}) != fingerprint([]transport.PortForward{b, a}) {
		t.Error("fingerprint changed when only the order did")
	}

	c := b
	c.TargetPort = 80
	if fingerprint([]transport.PortForward{a, b}) == fingerprint([]transport.PortForward{a, c}) {
		t.Error("fingerprint did not change when a forward did")
	}
	if fingerprint(nil) == fingerprint([]transport.PortForward{a}) {
		t.Error("an empty set and a non-empty one share a fingerprint")
	}
}

func TestDescribeForwardsIsSafeWithNothingToSay(t *testing.T) {
	// An operator who manages their own network still gets told what is needed;
	// an empty fleet on their node must not look like a failure.
	describeForwards(slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	describeForwards(slog.New(slog.NewTextHandler(io.Discard, nil)), []transport.PortForward{
		{PublicPort: 20001, TargetIP: "10.10.4.20", TargetPort: 22},
	})
}

func TestForwardsRestoreIsOneCommitPerTable(t *testing.T) {
	// The whole point of going through iptables-restore: a table gets the new
	// set in one commit or keeps the old one. Rules outside a table block, or a
	// block without COMMIT, would undo that.
	subnet := mustSubnet(t, "10.10.4.1", 22)
	out := forwardsRestore(slog.New(slog.NewTextHandler(io.Discard, nil)), []transport.PortForward{sshForward()}, subnet)

	want := "*nat\n" +
		":BUNK-DNAT - [0:0]\n" +
		":BUNK-SNAT - [0:0]\n" +
		"-A BUNK-DNAT -p tcp --dport 20001 -j DNAT --to-destination 10.10.4.20:22\n" +
		"-A BUNK-SNAT -s 10.10.4.0/22 -d 10.10.4.20 -p tcp --dport 22 -j MASQUERADE\n" +
		"COMMIT\n" +
		"*filter\n" +
		":BUNK-FWD - [0:0]\n" +
		"-A BUNK-FWD -p tcp -d 10.10.4.20 --dport 22 -j ACCEPT\n" +
		"COMMIT\n"
	if out != want {
		t.Errorf("restore input:\n%s\nwant:\n%s", out, want)
	}
}

func TestForwardsRestoreWithNothingLeftStillEmptiesTheChains(t *testing.T) {
	// The last VPS on a node is deleted. Its forward has to go too, so the
	// chains are declared — and thereby emptied — even with no rules for them.
	out := forwardsRestore(slog.New(slog.NewTextHandler(io.Discard, nil)), nil, nil)
	for _, decl := range []string{":BUNK-DNAT - [0:0]", ":BUNK-SNAT - [0:0]", ":BUNK-FWD - [0:0]"} {
		if !strings.Contains(out, decl) {
			t.Errorf("chain not declared: %s", decl)
		}
	}
	if strings.Contains(out, "-A ") {
		t.Errorf("rules with no forwards:\n%s", out)
	}
}

func TestForwardsRestoreSkipsOnlyTheBadEntry(t *testing.T) {
	subnet := mustSubnet(t, "10.10.4.1", 22)
	bad := transport.PortForward{PublicPort: 20002, TargetIP: "8.8.8.8", TargetPort: 53}
	out := forwardsRestore(slog.New(slog.NewTextHandler(io.Discard, nil)), []transport.PortForward{bad, sshForward()}, subnet)

	if strings.Contains(out, "8.8.8.8") {
		t.Errorf("an off-subnet target made it into the rules:\n%s", out)
	}
	if !strings.Contains(out, "--dport 20001") {
		t.Errorf("the good forward was dropped with the bad one:\n%s", out)
	}
}
