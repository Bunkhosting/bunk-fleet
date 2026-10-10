// Package transport defines the bunk-agent's client contract with the
// control plane.
//
// The agent always DIALS OUT (so it works behind NAT): it enrolls once with a
// one-time token to obtain a durable node identity and credentials, then
// periodically POSTs capacity heartbeats and long-polls for commands
// (provision / delete). Browser consoles ride the same outbound-only rule: the
// control plane never dials the node, it asks the node to dial back
// (DialConsoleRelay).
package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/coder/websocket"
)

// CommandKind enumerates the command verbs the control plane may dispatch.
type CommandKind string

const (
	// CmdProvision asks the agent to create a VM. Payload is a JSON-encoded
	// provider.VMSpec-shaped object (decoded by the caller).
	CmdProvision CommandKind = "provision"
	// CmdDelete asks the agent to destroy a VM. Payload carries the target id.
	CmdDelete CommandKind = "delete"
	// CmdStart powers on a stopped VM. Payload carries the target id.
	CmdStart CommandKind = "start"
	// CmdStop powers off a running VM. Payload carries the target id.
	CmdStop CommandKind = "stop"
	// CmdPause suspends (to RAM) a running VM. Payload carries the target id.
	CmdPause CommandKind = "pause"
	// CmdResume un-suspends a paused VM. Payload carries the target id.
	CmdResume CommandKind = "resume"

	// CmdReboot restarts a running VM from the inside: the guest OS is asked to
	// shut down and comes back up. Not a reset -- that is pulling the power on a
	// customer's disk, and stays an explicit stop followed by a start.
	CmdReboot CommandKind = "reboot"
	// CmdBackup archives a guest's disk to the node's own storage. Payload carries
	// the target id; the result carries the archive's handle and size.
	CmdBackup CommandKind = "backup"
	// CmdDeleteBackup removes one archive by the handle a backup produced.
	CmdDeleteBackup CommandKind = "delete_backup"
	// CmdRestoreBackup overwrites a guest's disk from an archive. Payload carries
	// the target id, the archive, and whether to start the guest afterwards.
	CmdRestoreBackup CommandKind = "restore_backup"
	// CmdConsoleConnect asks the agent to bridge one browser console to a VPS on
	// this node. Unlike the verbs above it changes nothing and reports no result:
	// it is a request to open a connection, delivered on the command poll because
	// that is the channel the agent is already holding open.
	CmdConsoleConnect CommandKind = "console_connect"
	// CmdInventory asks this node which guests it actually has. Het antwoord gaat
	// niet over één VPS maar over de hele node, zodat het control plane beide
	// richtingen ziet: wat wij denken te hebben en niet bestaat, en wat er draait
	// zonder dat wij het weten.
	CmdInventory CommandKind = "inventory"

	// CmdUpdate asks this node to check whether a newer agent is published and,
	// if so, install it. The command carries no version: the node compares the
	// published checksum with its own binary and does nothing when they match,
	// so the control plane can send this blind after every deploy.
	CmdUpdate CommandKind = "update"
)

// EnrollRequest is sent once to exchange a one-time token for node credentials.
type EnrollRequest struct {
	// Token is the one-time enrollment token issued by the control plane.
	Token string `json:"token"`
	// Hypervisor identifies the local backend, e.g. "proxmox".
	Hypervisor string `json:"hypervisor"`
	// AgentVersion is the build/version string of this agent.
	AgentVersion string `json:"agent_version"`
	// VpsGateway/VpsCidrPrefix/VpsRangeStart/VpsRangeEnd describe this worker's
	// VPS IP range so the control plane can allocate non-conflicting addresses.
	VpsGateway    string `json:"vps_gateway,omitempty"`
	VpsCidrPrefix int    `json:"vps_cidr_prefix,omitempty"`
	VpsRangeStart string `json:"vps_range_start,omitempty"`
	VpsRangeEnd   string `json:"vps_range_end,omitempty"`
	// OwnerEmail names the person who will manage this node from the dashboard.
	// The control plane resolves it to an account; only that account may change
	// this node's settings. Empty leaves ownership to whoever minted the token.
	OwnerEmail string `json:"owner_email,omitempty"`
}

// VpsNetwork is the IP-range part of a worker's VPS network, sent at enrollment.
type VpsNetwork struct {
	Gateway    string
	CidrPrefix int
	RangeStart string
	RangeEnd   string
}

// EnrollResponse carries the durable identity and credentials assigned to the
// node after a successful enrollment.
type EnrollResponse struct {
	// NodeID is the stable identifier assigned to this worker node.
	NodeID string `json:"node_id"`
	// AgentToken is the long-lived bearer token used to authenticate
	// subsequent heartbeat and command requests.
	AgentToken string `json:"agent_token"`
	// VpsNetwork is the customer network this node must serve. The control plane
	// assigns it when the agent did not declare one, so it is not necessarily
	// what was sent — it is what the control plane will address VPSes on.
	VpsNetwork *AssignedNetwork `json:"vps_network,omitempty"`
}

// AssignedNetwork is the VPS network the control plane holds for this node.
type AssignedNetwork struct {
	Gateway    string `json:"gateway"`
	CidrPrefix int    `json:"cidr_prefix"`
	RangeStart string `json:"range_start"`
	RangeEnd   string `json:"range_end"`
}

// Heartbeat is the periodic capacity report posted to the control plane.
type Heartbeat struct {
	// NodeID identifies the reporting node.
	NodeID string `json:"node_id"`
	// At is the timestamp the heartbeat was generated.
	At time.Time `json:"at"`
	// TotalVCPU/AvailVCPU/... mirror provider.Capacity. They are flat ints so
	// the transport package stays free of a provider import cycle; the caller
	// translates a provider.Capacity into this shape.
	TotalVCPU   int `json:"total_vcpu"`
	AvailVCPU   int `json:"avail_vcpu"`
	TotalRAMMB  int `json:"total_ram_mb"`
	AvailRAMMB  int `json:"avail_ram_mb"`
	TotalDiskGB int `json:"total_disk_gb"`
	AvailDiskGB int `json:"avail_disk_gb"`
	// Version is the build this agent is running, stamped in at link time. The
	// control plane records it so "which nodes still run the old binary" is a
	// question the dashboard can answer, instead of one you answer by searching
	// a stripped binary for a log string.
	Version string `json:"agent_version,omitempty"`
	// CapacityError says why this heartbeat carries no measured capacity. An
	// agent that cannot reach its hypervisor is still alive and must still say
	// so: without this the control plane sees nothing at all and marks the node
	// offline, which looks exactly like a machine that is switched off and hides
	// the one fact the operator needs. Empty on a normal heartbeat.
	CapacityError string `json:"capacity_error,omitempty"`
	// NetworkNote is iets over het VPS-netwerk van deze node dat een operator wil
	// weten maar dat de node niet uit de verkoop haalt: een vermoeden, geen
	// vaststelling. Leeg als er niets te melden valt, en dan haalt het control
	// plane een eerdere notitie weg -- hij verdwijnt dus vanzelf zodra het is
	// rechtgezet. Een vaststelling gaat in CapacityError.
	NetworkNote string `json:"network_note,omitempty"`
}

// Command is a single instruction dispatched by the control plane.
type Command struct {
	// ID uniquely identifies the command for acknowledgement/idempotency.
	ID string `json:"id"`
	// Kind is the verb (provision, delete, ...).
	Kind CommandKind `json:"kind"`
	// VPSID names the machine this command is about; empty for a command about
	// the node itself (inventory, update) and for a control plane too old to
	// send it. The agent uses it to decide what may run next to what: see
	// werkers.go.
	VPSID string `json:"vps_id"`
	// Payload is the verb-specific body, decoded by the agent.
	Payload json.RawMessage `json:"payload"`
}

// CommandResult is the agent's report of how a dispatched command resolved. It
// is POSTed back to the control plane keyed by the originating command ID.
type CommandResult struct {
	// Status is the terminal outcome, typically "done" or "failed".
	Status string `json:"status"`
	// VMID is the provider-native guest identifier, when one was produced.
	VMID string `json:"vm_id"`
	// IP is the primary IPv4 address of the guest, when known.
	IP string `json:"ip"`
	// Error carries a human-readable failure reason when Status is "failed".
	Error string `json:"error"`
	// VolID and SizeBytes describe the archive a backup produced. Empty for every
	// other kind of command.
	VolID     string `json:"volid,omitempty"`
	SizeBytes int64  `json:"size_bytes,omitempty"`
	// Guests is elk gast-id dat deze node kent. Alleen gevuld door een
	// inventory-commando; leeg bij alle andere.
	Guests []string `json:"guests,omitempty"`
}

// Client is the HTTP control-plane client. It is safe for concurrent use.
type Client struct {
	baseURL string
	http    *http.Client

	// token is the bearer credential set after Enroll (or supplied directly).
	token  string
	nodeID string

	// logger is waar de commando-poll zijn fouten meldt. Zonder logger zag een
	// operator wel mislukte hartslagen, maar nooit dat het ophalen van werk al
	// een uur faalde (een ingetrokken token, een kapot antwoord).
	logger *slog.Logger
}

// SetLogger geeft de client een logger voor fouten die anders onzichtbaar
// blijven, zoals een commando-poll die blijft mislukken.
func (c *Client) SetLogger(l *slog.Logger) { c.logger = l }

func (c *Client) log() *slog.Logger {
	if c.logger != nil {
		return c.logger
	}
	return slog.Default()
}

// New returns a Client targeting the given control-plane base URL.
func New(baseURL string, httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		http:    httpClient,
	}
}

// NodeID returns the enrolled node identity (empty until Enroll succeeds or
// SetCredentials is called).
func (c *Client) NodeID() string { return c.nodeID }

// SetCredentials installs a previously-obtained identity and token, e.g. when
// loaded from disk so the agent need not re-enroll on every restart.
func (c *Client) SetCredentials(nodeID, token string) {
	c.nodeID = nodeID
	c.token = token
}

// post is a small helper that marshals body, performs an authenticated POST and
// decodes the JSON response into out (which may be nil).
func (c *Client) post(ctx context.Context, path string, body, out any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("transport: marshal %s: %w", path, err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, bytes.NewReader(buf))
	if err != nil {
		return fmt.Errorf("transport: build %s: %w", path, err)
	}
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("transport: %s: %w", path, err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("transport: %s: status %d: %s", path, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	if out == nil {
		return nil
	}
	// Een leeg antwoord is geen fout. Een control plane dat nog 204 zonder body
	// geeft -- een oudere versie, of een endpoint dat niets terug hoeft te zeggen
	// -- moet deze agent niet laten struikelen. De aanroeper houdt dan de
	// nulwaarde, wat voor instellingen precies "niets gewijzigd" betekent.
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("transport: decode %s: %w", path, err)
	}
	return nil
}

// Enroll exchanges a one-time token for node credentials and stores them on the
// Client for subsequent calls.
// Version is the agent build string sent at enrollment. Override at build time
// with -ldflags "-X github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport.Version=<v>".
var Version = "dev"

func (c *Client) Enroll(ctx context.Context, token, hypervisor, ownerEmail string, net VpsNetwork) (EnrollResponse, error) {
	if token == "" {
		return EnrollResponse{}, errors.New("transport: empty enrollment token")
	}
	if hypervisor == "" {
		hypervisor = "proxmox"
	}
	var out EnrollResponse
	req := EnrollRequest{
		Token:         token,
		Hypervisor:    hypervisor,
		AgentVersion:  Version,
		VpsGateway:    net.Gateway,
		VpsCidrPrefix: net.CidrPrefix,
		VpsRangeStart: net.RangeStart,
		VpsRangeEnd:   net.RangeEnd,
		OwnerEmail:    ownerEmail,
	}
	if err := c.post(ctx, "/v1/enroll", req, &out); err != nil {
		return EnrollResponse{}, err
	}
	if out.NodeID == "" || out.AgentToken == "" {
		return EnrollResponse{}, errors.New("transport: enrollment response missing node_id/agent_token")
	}
	c.SetCredentials(out.NodeID, out.AgentToken)
	return out, nil
}

// SendHeartbeat posts a single capacity heartbeat.
func (c *Client) SendHeartbeat(ctx context.Context, hb Heartbeat) (NodeSettings, error) {
	if c.token == "" {
		return NodeSettings{}, errors.New("transport: not enrolled (no agent token)")
	}
	if hb.NodeID == "" {
		hb.NodeID = c.nodeID
	}
	var out HeartbeatResponse
	if err := c.post(ctx, "/v1/heartbeat", hb, &out); err != nil {
		return NodeSettings{}, err
	}
	return out.Settings, nil
}

// NodeSettings is what the owner configured for this node in the dashboard. The
// control plane returns it on every heartbeat, so a change lands within one
// interval without anyone logging into the machine. A zero value for a field
// means "not configured": the agent keeps whatever its own config says, so a
// node nobody has touched does not suddenly behave differently.
type NodeSettings struct {
	OfferVCPU         int `json:"offer_vcpu"`
	OfferRAMMB        int `json:"offer_ram_mb"`
	OfferDiskGB       int `json:"offer_disk_gb"`
	VMIDMin           int `json:"vmid_min"`
	VMIDMax           int `json:"vmid_max"`
	VCPUOversubscribe int `json:"vcpu_oversubscribe"`
	// Bridge en VLAN zijn pointers omdat "niet ingesteld" hier niet samenvalt
	// met de nulwaarde: een lege bridge betekent "neem over van de template" en
	// VLAN 0 betekent "untagged". Beide zijn geldige keuzes, dus alleen null
	// mag "laat mijn eigen config staan" betekenen.
	Bridge *string `json:"vps_bridge"`
	VLAN   *int    `json:"vps_vlan"`
	// Het VPS-netwerk zelf. Kwam alleen bij de inschrijving mee, zodat een
	// wijziging in het control plane een draaiende agent nooit bereikte: de
	// console weigerde dan elk adres in het nieuwe net. Null betekent "niet
	// ingesteld" en laat staan wat de agent al heeft.
	VpsGateway    *string `json:"vps_gateway"`
	VpsCidrPrefix *int    `json:"vps_cidr_prefix"`
}

// HeartbeatResponse is the control plane's answer to a heartbeat.
type HeartbeatResponse struct {
	Settings NodeSettings `json:"settings"`
}

// ReportResult posts the terminal outcome of a dispatched command back to the
// control plane, keyed by the originating command ID. It reuses the
// Bearer-authenticated post helper.
func (c *Client) ReportResult(ctx context.Context, commandID string, res CommandResult) error {
	if c.token == "" {
		return errors.New("transport: not enrolled (no agent token)")
	}
	if commandID == "" {
		return errors.New("transport: ReportResult requires a command ID")
	}
	path := "/v1/commands/" + url.PathEscape(commandID) + "/result"
	return c.post(ctx, path, res, nil)
}

// Commands long-polls the control plane and delivers dispatched commands on the
// returned channel. The channel is closed when ctx is cancelled or a fatal
// error occurs. Transient poll errors are retried with a backoff; this is the
// documented persistent-reconnection method for the command stream.
//
// Each long-poll request blocks server-side until a command is available or the
// poll window elapses (returning an empty list), keeping the agent reachable
// from behind NAT without inbound connectivity.
func (c *Client) Commands(ctx context.Context) (<-chan Command, error) {
	if c.token == "" {
		return nil, errors.New("transport: not enrolled (no agent token)")
	}
	out := make(chan Command)

	go func() {
		defer close(out)
		backoff := time.Second
		missers := 0
		const maxBackoff = 30 * time.Second
		const pollFloor = 2 * time.Second

		for {
			if ctx.Err() != nil {
				return
			}
			cmds, err := c.pollCommands(ctx)
			if err != nil {
				// On cancellation, exit quietly.
				if ctx.Err() != nil {
					return
				}
				missers++
				// De eerste fout en daarna elke tiende: zichtbaar, maar geen
				// regel elke seconde zolang het control plane weg is.
				if missers == 1 || missers%10 == 0 {
					c.log().Warn("commands poll failing", "attempts", missers, "err", err)
				}
				// Een geweigerd token gaat niet vanzelf over. Langzaam blijven
				// proberen (een operator kan het herstellen), maar niet elke seconde.
				if strings.Contains(err.Error(), "status 401") || strings.Contains(err.Error(), "status 403") {
					backoff = maxBackoff
				}
				// Transient error: back off and retry. Met spreiding: na een
				// herstart van het control plane kwamen anders alle agents in
				// precies hetzelfde ritme terug.
				select {
				case <-ctx.Done():
					return
				case <-time.After(spreid(backoff)):
				}
				if backoff < maxBackoff {
					backoff *= 2
					if backoff > maxBackoff {
						backoff = maxBackoff
					}
				}
				continue
			}
			if missers > 0 {
				c.log().Info("commands poll recovered", "failed_attempts", missers)
				missers = 0
			}
			backoff = time.Second // reset after a successful poll
			for _, cmd := range cmds {
				select {
				case <-ctx.Done():
					return
				case out <- cmd:
				}
			}
			// The control plane answers command polls immediately (no
			// server-side long-poll), so on an empty result floor-sleep before
			// re-polling — otherwise this is a tight CPU loop hammering the CP.
			if len(cmds) == 0 {
				select {
				case <-ctx.Done():
					return
				case <-time.After(pollFloor):
				}
			}
		}
	}()

	return out, nil
}

// pollCommands performs a single long-poll request and returns any pending
// commands (possibly empty).
func (c *Client) pollCommands(ctx context.Context) ([]Command, error) {
	pollURL := c.baseURL + "/v1/commands?node_id=" + url.QueryEscape(c.nodeID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, pollURL, nil)
	if err != nil {
		return nil, fmt.Errorf("transport: build commands poll: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("transport: commands poll: %w", err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("transport: commands poll: status %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}

	// The control plane returns a bare JSON array of commands:
	//   [{"id":"...","kind":"provision","payload":{...}}]
	if len(bytes.TrimSpace(raw)) == 0 {
		return nil, nil
	}
	var cmds []Command
	if err := json.Unmarshal(raw, &cmds); err != nil {
		return nil, fmt.Errorf("transport: decode commands: %w", err)
	}
	return cmds, nil
}

// DialConsoleRelay opens the node half of one console session: a WebSocket to
// the control plane, returned as a net.Conn so the caller can simply copy bytes
// between it and the VPS's SSH port.
//
// WebSocket rather than a streaming HTTP request because the path to the control
// plane runs through a CDN, and CDNs buffer request bodies — which would deadlock
// an interactive terminal — but forward WebSockets verbatim.
func (c *Client) DialConsoleRelay(ctx context.Context, relayToken string) (net.Conn, error) {
	if c.token == "" {
		return nil, errors.New("transport: not enrolled (no agent token)")
	}
	endpoint, err := consoleRelayURL(c.baseURL, relayToken)
	if err != nil {
		return nil, err
	}

	conn, _, err := websocket.Dial(ctx, endpoint, &websocket.DialOptions{
		HTTPClient: c.http,
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + c.token}},
	})
	if err != nil {
		return nil, fmt.Errorf("transport: console relay dial: %w", err)
	}

	// The SSH stream is arbitrary binary and can be long-lived and idle (someone
	// leaves a terminal open), so no read limit and no message-size assumptions.
	conn.SetReadLimit(-1)
	return websocket.NetConn(context.WithoutCancel(ctx), conn, websocket.MessageBinary), nil
}

// consoleRelayURL turns the control-plane base URL into the ws:// or wss:// URL
// of the relay endpoint, carrying the relay token.
func consoleRelayURL(baseURL, relayToken string) (string, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return "", fmt.Errorf("transport: bad control plane URL %q: %w", baseURL, err)
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return "", fmt.Errorf("transport: control plane URL has no http(s) scheme: %q", baseURL)
	}
	u.Path = strings.TrimSuffix(u.Path, "/") + "/v1/console-relay"
	u.RawQuery = url.Values{"token": {relayToken}}.Encode()
	return u.String(), nil
}

// PortForward is one public_port -> vps_ip:target_port mapping the node should
// be enforcing. Customers on a node share its public address and are told apart
// by port.
type PortForward struct {
	PublicPort int    `json:"public_port"`
	TargetIP   string `json:"target_ip"`
	TargetPort int    `json:"target_port"`
	Protocol   string `json:"protocol"`
}

// PortForwards asks the control plane what this node's firewall should say.
//
// Desired state, not a change feed: the answer is the complete set, so an agent
// that was offline converges on its next poll rather than having missed the
// events it slept through.
func (c *Client) PortForwards(ctx context.Context) ([]PortForward, error) {
	if c.token == "" {
		return nil, errors.New("transport: not enrolled (no agent token)")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/v1/port-forwards", nil)
	if err != nil {
		return nil, fmt.Errorf("transport: build port-forward request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("transport: port-forward poll: %w", err)
	}
	defer resp.Body.Close()

	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("transport: port-forward poll: status %d: %s",
			resp.StatusCode, strings.TrimSpace(string(raw)))
	}

	var out struct {
		Forwards []PortForward `json:"forwards"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("transport: decode port forwards: %w", err)
	}
	return out.Forwards, nil
}

// spreid geeft een wachttijd terug tussen 80% en 120% van d.
func spreid(d time.Duration) time.Duration {
	if d <= 0 {
		return d
	}
	return d*8/10 + time.Duration(rand.Int64N(int64(d)*4/10+1))
}
