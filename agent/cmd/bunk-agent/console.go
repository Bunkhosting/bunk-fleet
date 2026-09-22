package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// consoleRequest is what the control plane puts on the command poll when a
// customer opens the browser console for a VPS on this node.
type consoleRequest struct {
	Token string `json:"token"`
	VpsID string `json:"vps_id"`
	Host  string `json:"host"`
	Port  int    `json:"port"`
}

// How long a single console session may last before the agent tears it down.
// The control plane has its own idle timeout; this is the backstop against a
// relay that is never closed from either end.
const consoleSessionTimeout = 4 * time.Hour

// allowedConsoleTarget decides whether the agent will open a TCP connection to
// `host` on behalf of the control plane.
//
// The control plane is trusted, but "trusted" is not a reason to be an open
// proxy: a bug or a compromised control plane should not be able to use every
// node in the fleet to reach addresses on the operator's own network. So the
// target must be an IP literal (a hostname would let DNS decide after the check),
// it must be a private address, and — when the node knows which subnet its VPSes
// live on — it must be inside that subnet.
//
// Link-local is refused explicitly rather than as a side effect: 169.254.169.254
// is the cloud metadata endpoint, and on a rented node that is credentials.
func allowedConsoleTarget(host string, assigned *net.IPNet) error {
	ip := net.ParseIP(host)
	if ip == nil {
		return fmt.Errorf("console: %q is not an IP address", host)
	}
	switch {
	case ip.IsLoopback():
		return fmt.Errorf("console: refusing loopback target %s", ip)
	case ip.IsLinkLocalUnicast(), ip.IsLinkLocalMulticast():
		return fmt.Errorf("console: refusing link-local target %s", ip)
	case ip.IsMulticast(), ip.IsUnspecified():
		return fmt.Errorf("console: refusing non-unicast target %s", ip)
	case !ip.IsPrivate():
		return fmt.Errorf("console: refusing non-private target %s", ip)
	}
	if assigned != nil && !assigned.Contains(ip) {
		return fmt.Errorf("console: %s is outside this node's VPS subnet %s", ip, assigned)
	}
	return nil
}

// handleConsoleConnect joins one console session: dial back to the control plane
// over the outbound WebSocket it is expecting, dial the VPS's SSH port on the
// node's own network, and copy bytes between the two until either side stops.
//
// It reports no result. A console request is not a command — there is no state to
// converge, and by the time a retry could happen the person has clicked again.
func handleConsoleConnect(ctx context.Context, logger *slog.Logger, cp *transport.Client, assigned *net.IPNet, payload json.RawMessage) {
	var req consoleRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		logger.Error("console: bad request payload", "err", err)
		return
	}
	if req.Token == "" {
		logger.Error("console: request without a relay token")
		return
	}
	if req.Port <= 0 || req.Port > 65535 {
		logger.Error("console: implausible port", "port", req.Port)
		return
	}
	if err := allowedConsoleTarget(req.Host, assigned); err != nil {
		logger.Error("console: refusing target", "err", err, "vps", req.VpsID)
		return
	}

	go func() {
		ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), consoleSessionTimeout)
		defer cancel()

		target := net.JoinHostPort(req.Host, fmt.Sprint(req.Port))

		vps, err := dialVPS(ctx, target)
		if err != nil {
			logger.Warn("console: cannot reach the VPS", "target", target, "err", err)
			// Dial back and close straight away. The relay carries SSH, not
			// text — anything written here would reach the control plane's SSH
			// client as a corrupt banner — so the message belongs on that side.
			// What this does is let the control plane find out NOW instead of
			// after the 15-second attach timeout, so the customer gets the
			// explanation while they are still looking at the screen.
			hangUp(ctx, logger, cp, req.Token)
			return
		}
		defer vps.Close()

		relay, err := cp.DialConsoleRelay(ctx, req.Token)
		if err != nil {
			logger.Warn("console: cannot dial the control plane back", "err", err)
			return
		}
		defer relay.Close()

		logger.Info("console session open", "vps", req.VpsID, "target", target)

		if pipe(ctx, relay, vps) {
			logger.Warn("console session hit the time limit and was closed",
				"vps", req.VpsID, "limit", consoleSessionTimeout.String())
		} else {
			logger.Info("console session closed", "vps", req.VpsID)
		}
	}()
}

// How long to keep trying the VPS's SSH port before giving up on the session.
// A guest that has just been provisioned refuses the connection outright rather
// than timing out — sshd is not listening yet — so a single attempt fails in
// milliseconds and reports a machine that is merely still booting as unreachable.
const (
	consoleDialWindow  = 12 * time.Second
	consoleDialRetryIn = 1500 * time.Millisecond
)

func dialVPS(ctx context.Context, target string) (net.Conn, error) {
	deadline := time.Now().Add(consoleDialWindow)
	dialer := &net.Dialer{Timeout: 5 * time.Second}

	for {
		conn, err := dialer.DialContext(ctx, "tcp", target)
		if err == nil {
			return conn, nil
		}
		if time.Now().After(deadline) || ctx.Err() != nil {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(consoleDialRetryIn):
		}
	}
}

// hangUp attaches to the relay and closes it immediately, which is how the agent
// says "there is nothing on the other end" without inventing a message channel.
// The control plane's SSH client sees the connection go, gives up, and tells the
// browser why in words the customer can act on.
func hangUp(ctx context.Context, logger *slog.Logger, cp *transport.Client, token string) {
	relay, err := cp.DialConsoleRelay(ctx, token)
	if err != nil {
		logger.Warn("console: cannot dial the control plane back to end the session", "err", err)
		return
	}
	_ = relay.Close()
	logger.Info("console: ended the session because the VPS did not answer")
}

// pipe copies in both directions and returns once either side closes, so a
// browser that goes away drops the SSH connection with it rather than leaving
// a half-open session on the customer's machine. Returns true when it stopped
// because ctx expired rather than because a side closed.
//
// Het wachten op ctx is geen extra zorgvuldigheid maar de reden dat de limiet
// van vier uur iets betekent. `io.Copy` kijkt nergens naar: hij blokkeert op een
// read tot de verbinding eronder dichtgaat. Zonder deze select liep de context
// af, gebeurde er niets, en bleef een sessie openstaan zolang de TCP-verbinding
// bleef staan -- een dichtgeklapte laptop stuurt geen FIN, dus dat is de
// normale manier waarop een sessie blijft hangen, niet de uitzonderlijke.
//
// Onderbreken kan alleen door de verbindingen te sluiten, en dat doet de
// aanroeper met zijn `defer`s zodra dit terugkeert. De kopieergoroutines lopen
// daarop stuk en eindigen.
func pipe(ctx context.Context, a, b net.Conn) bool {
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(a, b); done <- struct{}{} }()
	go func() { _, _ = io.Copy(b, a); done <- struct{}{} }()

	select {
	case <-done:
		return false
	case <-ctx.Done():
		return true
	}
}

// assignedSubnet is the network this node's VPSes live on, as a mask the console
// target check can be held against.
//
// Welk netwerk dat is, beantwoordt `vpsNetwerkVan` -- dezelfde functie die het
// instellen van de bridge gebruikt. Dat is met opzet: twee antwoorden op die
// vraag betekende ooit dat de console een adres goedkeurde op een bridge die
// nooit was ingericht.
func assignedSubnet(st persistedState, cfg config.VpsNetworkConfig) *net.IPNet {
	netwerk := vpsNetwerkVan(st, cfg)
	if netwerk.Gateway == "" {
		return nil
	}
	if subnet, err := netwerk.subnet(); err == nil {
		return subnet
	}
	return nil
}
