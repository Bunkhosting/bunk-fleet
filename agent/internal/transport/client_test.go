package transport

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// This is the whole agent-side protocol: enrol, heartbeat, poll, report. It runs
// outbound-only from a node that may be someone else's hardware, so what it
// sends and what it refuses to send without credentials is the security surface.

type capture struct {
	mu       sync.Mutex
	requests []seenRequest
	handler  func(http.ResponseWriter, *http.Request)
	srv      *httptest.Server
}

type seenRequest struct {
	method string
	path   string
	// raw is the request line as it went over the wire, before the server
	// decoded percent-escapes back into URL.Path.
	raw   string
	query string
	auth  string
	body  []byte
}

func newCapture(t *testing.T, handler func(http.ResponseWriter, *http.Request)) *capture {
	t.Helper()
	c := &capture{handler: handler}
	c.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		c.mu.Lock()
		c.requests = append(c.requests, seenRequest{
			method: r.Method,
			path:   r.URL.Path,
			raw:    r.RequestURI,
			query:  r.URL.RawQuery,
			auth:   r.Header.Get("Authorization"),
			body:   body,
		})
		c.mu.Unlock()
		c.handler(w, r)
	}))
	t.Cleanup(c.srv.Close)
	return c
}

func (c *capture) client() *Client {
	return New(c.srv.URL, c.srv.Client())
}

func (c *capture) last() seenRequest {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.requests) == 0 {
		return seenRequest{}
	}
	return c.requests[len(c.requests)-1]
}

func (c *capture) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.requests)
}

func TestEnrollStoresTheCredentialsItReceives(t *testing.T) {
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"node_id":"n-1","agent_token":"tok-abc"}`))
	})
	c := cap.client()

	got, err := c.Enroll(context.Background(), "one-time-token", "proxmox", "beheerder@bunk.test", VpsNetwork{
		Gateway: "10.10.0.1", CidrPrefix: 22, RangeStart: "10.10.0.20", RangeEnd: "10.10.3.250",
	})
	if err != nil {
		t.Fatalf("Enroll: %v", err)
	}
	if got.NodeID != "n-1" || got.AgentToken != "tok-abc" {
		t.Fatalf("Enroll = %+v", got)
	}
	if c.NodeID() != "n-1" {
		t.Errorf("NodeID() = %q, want n-1", c.NodeID())
	}

	// Enrolment is the one call that carries no bearer: the one-time token in the
	// body IS the credential, and there is nothing else to present yet.
	req := cap.last()
	if req.auth != "" {
		t.Errorf("Authorization on enroll = %q, want empty", req.auth)
	}

	var sent EnrollRequest
	if err := json.Unmarshal(req.body, &sent); err != nil {
		t.Fatalf("enroll body: %v", err)
	}
	if sent.Token != "one-time-token" || sent.Hypervisor != "proxmox" {
		t.Errorf("enroll body = %+v", sent)
	}
	// The control plane carves this node's subnet out of what it declares here;
	// dropping a field silently would place VPSes on the wrong network.
	if sent.VpsGateway != "10.10.0.1" || sent.VpsCidrPrefix != 22 ||
		sent.VpsRangeStart != "10.10.0.20" || sent.VpsRangeEnd != "10.10.3.250" {
		t.Errorf("the declared network did not survive: %+v", sent)
	}
}

func TestEnrollDefaultsTheHypervisor(t *testing.T) {
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"node_id":"n","agent_token":"t"}`))
	})

	if _, err := cap.client().Enroll(context.Background(), "tok", "", "", VpsNetwork{}); err != nil {
		t.Fatalf("Enroll: %v", err)
	}

	var sent EnrollRequest
	_ = json.Unmarshal(cap.last().body, &sent)
	if sent.Hypervisor != "proxmox" {
		t.Errorf("hypervisor = %q, want the proxmox default", sent.Hypervisor)
	}
}

func TestEnrollRefusesAnEmptyToken(t *testing.T) {
	cap := newCapture(t, func(http.ResponseWriter, *http.Request) {})

	if _, err := cap.client().Enroll(context.Background(), "", "proxmox", "", VpsNetwork{}); err == nil {
		t.Fatal("Enroll accepted an empty token")
	}
	if cap.count() != 0 {
		t.Error("it called the control plane with an empty token anyway")
	}
}

func TestEnrollRejectsAHalfAnswer(t *testing.T) {
	// A 200 carrying no agent_token would otherwise leave the agent "enrolled"
	// with no credential, failing every later call for no visible reason.
	for _, body := range []string{`{"node_id":"n-1"}`, `{"agent_token":"t"}`, `{}`} {
		cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(body))
		})
		c := cap.client()

		if _, err := c.Enroll(context.Background(), "tok", "proxmox", "", VpsNetwork{}); err == nil {
			t.Errorf("Enroll accepted %s", body)
		}
		if c.NodeID() != "" {
			t.Errorf("it stored credentials from %s", body)
		}
	}
}

func TestEnrollSurfacesARejection(t *testing.T) {
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":"token expired"}`))
	})

	_, err := cap.client().Enroll(context.Background(), "stale", "proxmox", "", VpsNetwork{})
	if err == nil || !strings.Contains(err.Error(), "token expired") {
		t.Fatalf("error = %v, want the control plane's reason", err)
	}
}

func TestAuthenticatedCallsRefuseToRunUnenrolled(t *testing.T) {
	// Every one of these would otherwise reach the control plane with no bearer
	// and be rejected there — one round trip per tick, from a node that has
	// nothing useful to say.
	cap := newCapture(t, func(http.ResponseWriter, *http.Request) {})
	c := cap.client()
	ctx := context.Background()

	if _, err := c.SendHeartbeat(ctx, Heartbeat{}); err == nil {
		t.Error("SendHeartbeat ran without credentials")
	}
	if err := c.ReportResult(ctx, "cmd-1", CommandResult{}); err == nil {
		t.Error("ReportResult ran without credentials")
	}
	if _, err := c.Commands(ctx); err == nil {
		t.Error("Commands ran without credentials")
	}
	if _, err := c.PortForwards(ctx); err == nil {
		t.Error("PortForwards ran without credentials")
	}
	if cap.count() != 0 {
		t.Errorf("unenrolled calls still hit the control plane: %d", cap.count())
	}
}

func TestHeartbeatCarriesTheBearerAndFillsInTheNodeID(t *testing.T) {
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	c := cap.client()
	c.SetCredentials("node-7", "tok-xyz")

	if _, err := c.SendHeartbeat(context.Background(), Heartbeat{AvailVCPU: 4}); err != nil {
		t.Fatalf("SendHeartbeat: %v", err)
	}

	req := cap.last()
	if req.auth != "Bearer tok-xyz" {
		t.Errorf("Authorization = %q", req.auth)
	}
	var hb Heartbeat
	_ = json.Unmarshal(req.body, &hb)
	if hb.NodeID != "node-7" {
		t.Errorf("node_id = %q, want it filled in from the client", hb.NodeID)
	}
}

func TestReportResultRequiresACommandID(t *testing.T) {
	cap := newCapture(t, func(http.ResponseWriter, *http.Request) {})
	c := cap.client()
	c.SetCredentials("n", "t")

	if err := c.ReportResult(context.Background(), "", CommandResult{}); err == nil {
		t.Fatal("ReportResult accepted an empty command id")
	}
	if cap.count() != 0 {
		t.Error("it posted to a path with an empty id segment")
	}
}

func TestReportResultEscapesTheCommandID(t *testing.T) {
	// The id comes off the wire. Pasting it into a path unescaped lets a
	// compromised control plane — or a mangled response — aim the POST elsewhere.
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	c := cap.client()
	c.SetCredentials("n", "t")

	_ = c.ReportResult(context.Background(), "../../v1/enroll", CommandResult{})

	// On the wire the separators must be percent-encoded, so the id stays one
	// path segment. (The server's URL.Path shows it decoded again; that is the
	// server's normalisation, not what the agent sent.)
	raw := cap.last().raw
	if !strings.Contains(raw, "%2F") {
		t.Errorf("request-uri = %q: the id was not escaped", raw)
	}
	if !strings.HasPrefix(raw, "/v1/commands/") || !strings.HasSuffix(raw, "/result") {
		t.Errorf("request-uri = %q: the id escaped its segment", raw)
	}
}

func TestCommandsDeliversWhatThePollReturns(t *testing.T) {
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`[{"id":"c-1","kind":"provision"},{"id":"c-2","kind":"delete"}]`))
	})
	c := cap.client()
	c.SetCredentials("node-9", "tok")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ch, err := c.Commands(ctx)
	if err != nil {
		t.Fatalf("Commands: %v", err)
	}

	for _, want := range []string{"c-1", "c-2"} {
		select {
		case cmd := <-ch:
			if cmd.ID != want {
				t.Errorf("got command %q, want %q", cmd.ID, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("no command %q arrived", want)
		}
	}

	// The node id rides in the query string; the control plane scopes the queue
	// with it, so losing it hands this node someone else's commands.
	if !strings.Contains(cap.last().query, "node_id=node-9") {
		t.Errorf("poll query = %q", cap.last().query)
	}
}

func TestCommandsKeepsPollingAfterAnError(t *testing.T) {
	// A control plane that is briefly down must not end the agent's command
	// stream: a node that stops polling stops existing, and nothing restarts it.
	var calls int
	var mu sync.Mutex
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		calls++
		n := calls
		mu.Unlock()

		if n == 1 {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		_, _ = w.Write([]byte(`[{"id":"c-after-failure","kind":"start"}]`))
	})
	c := cap.client()
	c.SetCredentials("n", "t")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ch, _ := c.Commands(ctx)

	select {
	case cmd := <-ch:
		if cmd.ID != "c-after-failure" {
			t.Errorf("got %q", cmd.ID)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the stream never recovered from a single failed poll")
	}
}

func TestCommandsClosesWhenTheContextIsCancelled(t *testing.T) {
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`[]`))
	})
	c := cap.client()
	c.SetCredentials("n", "t")

	ctx, cancel := context.WithCancel(context.Background())
	ch, _ := c.Commands(ctx)
	cancel()

	select {
	case _, open := <-ch:
		if open {
			t.Error("a command arrived after cancellation")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the command channel was never closed")
	}
}

func TestEmptyPollIsNotAnError(t *testing.T) {
	// The control plane answers an empty queue with an empty body on some paths
	// and "[]" on others. Neither is a failure.
	for _, body := range []string{``, `   `, `[]`} {
		cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(body))
		})
		c := cap.client()
		c.SetCredentials("n", "t")

		cmds, err := c.pollCommands(context.Background())
		if err != nil {
			t.Errorf("pollCommands(%q) = %v", body, err)
		}
		if len(cmds) != 0 {
			t.Errorf("pollCommands(%q) returned %d commands", body, len(cmds))
		}
	}
}

func TestPortForwardsUnwrapsTheEnvelope(t *testing.T) {
	cap := newCapture(t, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"forwards":[{"public_port":10022,"target_ip":"10.10.0.21","target_port":22,"protocol":"tcp"}]}`))
	})
	c := cap.client()
	c.SetCredentials("n", "tok")

	forwards, err := c.PortForwards(context.Background())
	if err != nil {
		t.Fatalf("PortForwards: %v", err)
	}
	if len(forwards) != 1 || forwards[0].PublicPort != 10022 || forwards[0].TargetIP != "10.10.0.21" {
		t.Fatalf("PortForwards = %+v", forwards)
	}
	if cap.last().auth != "Bearer tok" {
		t.Errorf("Authorization = %q", cap.last().auth)
	}
}

// De wachttijd na een mislukte poll ligt tussen 80% en 120% van de backoff, zodat
// agents na een herstart van het control plane niet in hetzelfde ritme
// terugkomen.
func TestSpreidBlijftBinnenDeMarge(t *testing.T) {
	d := 10 * time.Second
	verschillend := map[time.Duration]bool{}
	for i := 0; i < 200; i++ {
		got := spreid(d)
		if got < 8*time.Second || got > 12*time.Second {
			t.Fatalf("spreid(%s) = %s, buiten 8s-12s", d, got)
		}
		verschillend[got] = true
	}
	if len(verschillend) < 10 {
		t.Errorf("nauwelijks spreiding: %d verschillende waarden", len(verschillend))
	}
	if spreid(0) != 0 {
		t.Error("spreid(0) is niet 0")
	}
}
