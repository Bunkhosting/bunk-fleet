// Package proxmox implements provider.Provider against the Proxmox VE REST
// API (/api2/json) using API-token authentication.
//
// Authentication uses the header:
//
//	Authorization: PVEAPIToken=USER@REALM!TOKENID=SECRET
//
// which requires no login ticket / CSRF dance and is well suited to an
// unattended agent.
package proxmox

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

// Config holds the connection parameters for a Proxmox VE node.
type Config struct {
	// Host is the base URL of the PVE API, e.g. "https://10.0.0.5:8006".
	Host string
	// Node is the cluster node name targeted by this agent, e.g. "pve".
	Node string
	// TokenID is the full token identifier "USER@REALM!TOKENID".
	TokenID string
	// TokenSecret is the secret UUID value of the API token.
	TokenSecret string
	// VerifySSL toggles TLS certificate verification. Many homelab PVE nodes
	// use self-signed certs, so this may be false in practice.
	VerifySSL bool
	// Fingerprint is the SHA-256 fingerprint of the certificate the PVE API is
	// expected to present, as 64 hex characters (colons allowed). It exists
	// because a stock Proxmox serves a self-signed certificate: verifying it
	// against the system roots fails ("certificate signed by unknown authority")
	// and the only advice left is to switch verification off entirely. Pinning
	// is the third answer -- it needs no CA and still notices when someone else
	// answers on that address. When set it replaces the chain check; VerifySSL
	// is then irrelevant.
	Fingerprint string
	// Bridge, when set, is forced as the VPS NIC bridge (else the template's NIC
	// is inherited). VLAN > 0 adds an 802.1q tag for a dedicated VPS network.
	Bridge string
	VLAN   int
	// BackupStorage is the PVE storage vzdump archives are written to. Empty
	// means "local", which is the storage every install has.
	BackupStorage string
	// VCPUOversubscribe is how many vCPUs may be handed out per physical core.
	// RAM cannot be oversubscribed -- hand out more than there is and something
	// gets killed -- but a vCPU is a share of time, not a piece of hardware, and
	// every hypervisor hands out more of them than it has cores. Counting them
	// like RAM means a host can never sell more vCPU than it physically has, and
	// stops selling entirely once its own guests use them up. Zero or less means
	// the default.
	VCPUOversubscribe int
	// VMIDMin/VMIDMax bound the ids Bunk may hand to the guests it creates.
	// Without them the agent takes whatever /cluster/nextid returns, which is the
	// lowest free id on the whole cluster -- so customer VPSes land in the middle
	// of the numbering the operator uses for their own machines. Both zero means
	// no bound, which is the old behaviour.
	VMIDMin int
	VMIDMax int
}

// Client is a Proxmox VE provider implementation.
//
// The mutex guards only the fields the control plane may change while the agent
// runs (see ApplySettings). Everything else is set once at construction. It is
// needed because the heartbeat loop applies settings on one goroutine while the
// command consumer creates VMs on another.
type Client struct {
	cfg  Config
	base string
	http *http.Client

	mu       sync.RWMutex
	settings provider.Settings
}

// ApplySettings takes the knobs the owner configured in the dashboard. A zero
// value leaves the local configuration in place rather than resetting it: "not
// configured" and "configured to zero" are different things, and only one of
// them should change how this node behaves.
func (c *Client) ApplySettings(s provider.Settings) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.settings = s
}

// oversubscribe / vmidRange return the effective values: what the control plane
// said, falling back to what this agent was started with.
func (c *Client) oversubscribe() int {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if c.settings.VCPUOversubscribe > 0 {
		return c.settings.VCPUOversubscribe
	}
	return c.cfg.VCPUOversubscribe
}

// netwerk geeft de bridge en het VLAN voor een nieuwe VPS-kaart. Wat de
// eigenaar in het dashboard zet wint van waarmee de agent gestart is; dat is de
// hele reden dat het daar staat. Het raakt alleen machines die hierna gemaakt
// worden -- een bestaande VPS verhangen zou hem van het net halen zonder dat
// iemand daarom vroeg.
func (c *Client) netwerk() (string, int) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	bridge := c.cfg.Bridge
	if c.settings.Bridge != "" {
		bridge = c.settings.Bridge
	}
	vlan := c.cfg.VLAN
	if c.settings.VLANIngesteld {
		vlan = c.settings.VLAN
	}
	return bridge, vlan
}

func (c *Client) vmidRange() (int, int) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	if c.settings.VMIDMin > 0 && c.settings.VMIDMax >= c.settings.VMIDMin {
		return c.settings.VMIDMin, c.settings.VMIDMax
	}
	return c.cfg.VMIDMin, c.cfg.VMIDMax
}

// compile-time assertion that Client satisfies provider.Provider.
var _ provider.Provider = (*Client)(nil)

// New constructs a Client from cfg. It returns an error if required fields are
// missing.
// safeBridge reports whether s is a non-empty, alphanumeric Proxmox bridge name,
// preventing injection of extra options into the net0 parameter string.
func safeBridge(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')) {
			return false
		}
	}
	return true
}

func New(cfg Config) (*Client, error) {
	if cfg.Host == "" {
		return nil, errors.New("proxmox: Host is required")
	}
	if cfg.Node == "" {
		return nil, errors.New("proxmox: Node is required")
	}
	if cfg.TokenID == "" || cfg.TokenSecret == "" {
		return nil, errors.New("proxmox: TokenID and TokenSecret are required")
	}
	host, err := normaliseerHost(cfg.Host)
	if err != nil {
		return nil, err
	}
	afdruk, err := normaliseerAfdruk(cfg.Fingerprint)
	if err != nil {
		return nil, err
	}
	if afdruk == "" {
		afdruk = afdrukVanEigenNode(host)
	}

	return &Client{
		cfg:  cfg,
		base: host + "/api2/json",
		http: httpClient(cfg.VerifySSL, afdruk),
	}, nil
}

// normaliseerAfdruk maakt van een ingetypte SHA-256-vingerafdruk de vorm waarin
// hij vergeleken wordt: kleine letters, zonder dubbele punten. Proxmox toont hem
// zelf met dubbele punten, dus die moeten erin mogen staan.
func normaliseerAfdruk(ruw string) (string, error) {
	afdruk := strings.ToLower(strings.NewReplacer(":", "", " ", "", "-", "").Replace(strings.TrimSpace(ruw)))
	if afdruk == "" {
		return "", nil
	}
	if len(afdruk) != sha256.Size*2 {
		return "", fmt.Errorf(
			"proxmox: %q is geen SHA-256-vingerafdruk; verwacht 64 hex-tekens (dubbele punten mogen)", ruw)
	}
	if _, err := hex.DecodeString(afdruk); err != nil {
		return "", fmt.Errorf("proxmox: vingerafdruk %q bevat iets dat geen hex is", ruw)
	}
	return afdruk, nil
}

// normaliseerHost maakt van wat een mens intypt een adres waar Go mee kan werken.
//
// Dit bestaat omdat de fout die eruit komt anders onvindbaar is. Wie
// `https:10.70.0.14:8006` intypt -- de twee schuine strepen vergeten -- krijgt
// van Go bij ELKE aanroep "http: no Host in request URL", en dat staat dan in
// het dashboard als reden waarom de node zijn hypervisor niet kan bevragen. Daar
// is niet uit op te maken dat er twee tekens ontbreken.
//
// Geaccepteerd: "10.0.0.5:8006" (schema erbij), "https://10.0.0.5:8006" (zoals
// het hoort) en "https:10.0.0.5:8006" (de typefout, gerepareerd). Alles zonder
// een bruikbaar adres erin wordt geweigerd met een fout die zegt wat er mis is.
func normaliseerHost(ruw string) (string, error) {
	host := strings.TrimSpace(strings.TrimRight(ruw, "/"))

	// De typefout: een schema met een dubbele punt maar zonder //.
	for _, schema := range []string{"https:", "http:"} {
		if strings.HasPrefix(host, schema) && !strings.HasPrefix(host, schema+"//") {
			host = schema + "//" + strings.TrimPrefix(host, schema)
		}
	}

	// Helemaal geen schema: https, want de PVE-API praat geen platte http.
	if !strings.Contains(host, "://") {
		host = "https://" + host
	}

	ontleed, err := url.Parse(host)
	if err != nil || ontleed.Host == "" {
		return "", fmt.Errorf(
			"proxmox: %q is geen bruikbaar adres voor de API; verwacht iets als https://10.0.0.5:8006",
			ruw)
	}

	return host, nil
}

// pveCertPad is waar Proxmox het certificaat van deze node neerzet. Variabel
// gemaakt zodat de test er een eigen bestand voor in de plaats kan zetten.
var pveCertPad = "/etc/pve/local/pve-ssl.pem"

// afdrukVanEigenNode pint het certificaat van de Proxmox op DEZE machine, en
// alleen dan.
//
// Een verse Proxmox is zelfondertekend. De ketencontrole kan daar niet op
// slagen, en het enige dat overbleef was verificatie uitzetten -- op elke node
// die zonder eigen CA wordt toegevoegd, met een token dat root is op die node.
//
// Praat de agent met de API op zijn eigen machine, dan is dat onnodig: het
// certificaat ligt ernaast op schijf. Dat van schijf lezen is geen
// vertrouwen-bij-eerste-gebruik maar het echte certificaat, en het pinnen ervan
// is strenger dan de ketencontrole ooit was.
//
// Alleen bij een loopback-adres, want alleen dan is "de API op dit adres" en
// "de Proxmox waarvan dit bestand is" gegarandeerd dezelfde machine.
func afdrukVanEigenNode(host string) string {
	ontleed, err := url.Parse(host)
	if err != nil {
		return ""
	}
	naam := ontleed.Hostname()
	if naam != "localhost" {
		ip := net.ParseIP(naam)
		if ip == nil || !ip.IsLoopback() {
			return ""
		}
	}

	pem, err := os.ReadFile(pveCertPad)
	if err != nil {
		return ""
	}
	blok, _ := pemDecode(pem)
	if blok == nil {
		return ""
	}
	som := sha256.Sum256(blok)
	return hex.EncodeToString(som[:])
}

// pemDecode haalt de DER-bytes uit het eerste CERTIFICATE-blok. Teruggegeven
// wordt wat er ondertekend is, zodat de som gelijk is aan die van het
// certificaat dat over de lijn komt.
func pemDecode(data []byte) ([]byte, []byte) {
	blok, rest := pem.Decode(data)
	if blok == nil || blok.Type != "CERTIFICATE" {
		return nil, rest
	}
	return blok.Bytes, rest
}

// httpClient builds an *http.Client for the PVE API. Three cases, in order of
// preference: a pinned fingerprint (verification zonder CA), the normal chain
// check, or no check at all.
func httpClient(verifySSL bool, afdruk string) *http.Client {
	tlsCfg := &tls.Config{
		InsecureSkipVerify: !verifySSL, //nolint:gosec // our own nodes, self-signed Proxmox certs
		MinVersion:         tls.VersionTLS12,
	}
	if afdruk != "" {
		// De keten kan niet kloppen -- het certificaat is zelfondertekend -- dus
		// die controle gaat uit en de vingerafdruk komt ervoor in de plaats. Dat
		// is strenger dan wat eronder staat, niet losser: elk ander certificaat
		// op dat adres valt hier om.
		tlsCfg.InsecureSkipVerify = true //nolint:gosec // vervangen door de controle hieronder
		tlsCfg.VerifyPeerCertificate = func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return errors.New("proxmox: de server stuurde geen certificaat")
			}
			gezien := sha256.Sum256(rawCerts[0])
			if hex.EncodeToString(gezien[:]) != afdruk {
				return fmt.Errorf(
					"proxmox: het certificaat van de API hoort niet bij deze node "+
						"(verwacht %s, gezien %s); is het vernieuwd, geef dan de nieuwe "+
						"vingerafdruk op in BUNK_PROXMOX_TLS_FINGERPRINT",
					afdruk, hex.EncodeToString(gezien[:]))
			}
			return nil
		}
	}
	tr := &http.Transport{TLSClientConfig: tlsCfg}
	return &http.Client{
		Timeout:   30 * time.Second,
		Transport: tr,
	}
}

// authHeader returns the value for the Authorization header.
func authHeader(tokenID, secret string) string {
	return "PVEAPIToken=" + tokenID + "=" + secret
}

// Name implements provider.Provider.
func (c *Client) Name() string { return "proxmox" }

// doJSON performs an authenticated request against the PVE API and decodes the
// JSON response into out (which may be nil). For POST/PUT, body is encoded as
// application/x-www-form-urlencoded from form.
func (c *Client) doJSON(ctx context.Context, method, path string, form url.Values, out any) error {
	var bodyReader io.Reader
	if form != nil {
		bodyReader = strings.NewReader(form.Encode())
	}

	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bodyReader)
	if err != nil {
		return fmt.Errorf("proxmox: build request: %w", err)
	}
	req.Header.Set("Authorization", authHeader(c.cfg.TokenID, c.cfg.TokenSecret))
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("proxmox: %s %s: %w", method, path, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return fmt.Errorf("proxmox: read body: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("proxmox: %s %s: status %d: %s", method, path, resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("proxmox: decode %s %s: %w", method, path, err)
	}
	return nil
}

// --- Capacity -------------------------------------------------------------

// nodeStatus mirrors the subset of GET /nodes/{node}/status we consume.
type nodeStatus struct {
	Data struct {
		CPUInfo struct {
			CPUs int `json:"cpus"`
		} `json:"cpuinfo"`
		Memory struct {
			Total int64 `json:"total"`
			Used  int64 `json:"used"`
			Free  int64 `json:"free"`
		} `json:"memory"`
		RootFS struct {
			Total int64 `json:"total"`
			Used  int64 `json:"used"`
			Avail int64 `json:"avail"`
			Free  int64 `json:"free"`
		} `json:"rootfs"`
	} `json:"data"`
}

// guestEntry mirrors entries from GET /nodes/{node}/qemu (the VM list).
type guestEntry struct {
	VMID   int     `json:"vmid"`
	Name   string  `json:"name"`
	Status string  `json:"status"`
	CPUs   float64 `json:"cpus"`
	MaxMem int64   `json:"maxmem"`
}

type guestList struct {
	Data []guestEntry `json:"data"`
}

// parseCapacity computes a Capacity snapshot from a node status payload and the
// list of guests.
//
// Both vCPU and memory availability are "what can still be promised": the node's
// physical total minus what running guests already have assigned. For memory
// that is deliberately NOT the node's free memory. Linux spends whatever it can
// on page cache, so a host with 4 GB genuinely spare reports a few hundred MB
// free; scheduling on that number refuses every placement. It is equally wrong
// in the other direction on a freshly booted host, where nothing is cached yet
// and the free figure counts memory that guests will claim the moment they are
// started.
//
// Disk stays filesystem-based: guest volumes are thin, so a 20 GB disk does not
// occupy 20 GB until it is written, and the binding constraint is what the
// filesystem has left.
//
// It is split out from Capacity so it can be unit-tested without a live PVE.
// defaultVCPUOversubscribe is the ratio used when none is configured. Three is
// the conservative end of what hosting providers run; it is a default, not a
// recommendation, and BUNK_VCPU_OVERSUBSCRIBE exists for the operator who knows
// their own workload.
const defaultVCPUOversubscribe = 3

func parseCapacity(ns nodeStatus, guests []guestEntry, oversubscribe int) provider.Capacity {
	const mib = 1 << 20
	const gib = 1 << 30

	if oversubscribe < 1 {
		oversubscribe = defaultVCPUOversubscribe
	}

	// Total stays the honest physical count: that is what this machine is, and it
	// is what an operator recognises in the panel. The oversubscription only
	// widens what may still be handed out.
	totalVCPU := ns.Data.CPUInfo.CPUs
	totalRAMMB := int(ns.Data.Memory.Total / mib)

	usedVCPU := 0
	usedRAMMB := 0
	for _, g := range guests {
		if g.Status == "running" {
			usedVCPU += int(g.CPUs)
			usedRAMMB += int(g.MaxMem / mib)
		}
	}

	availVCPU := totalVCPU*oversubscribe - usedVCPU
	if availVCPU < 0 {
		availVCPU = 0
	}

	availRAMMB := totalRAMMB - usedRAMMB
	if availRAMMB < 0 {
		availRAMMB = 0
	}

	out := provider.Capacity{
		TotalVCPU:   totalVCPU,
		AvailVCPU:   availVCPU,
		TotalRAMMB:  totalRAMMB,
		AvailRAMMB:  availRAMMB,
		TotalDiskGB: int(ns.Data.RootFS.Total / gib),
		AvailDiskGB: int(ns.Data.RootFS.Avail / gib),
	}
	// RootFS may report "free" rather than "avail" on some versions.
	if out.AvailDiskGB == 0 && ns.Data.RootFS.Free > 0 {
		out.AvailDiskGB = int(ns.Data.RootFS.Free / gib)
	}
	return out
}

// Capacity implements provider.Provider. It queries node status and the guest
// lists and combines them on a best-effort basis.
//
// Both QEMU guests and LXC containers count. A node is rarely only Bunk's: on
// the first one the router, the control plane and three containers were already
// there, and the containers alone held 2.5 GB. Asking only for /qemu made that
// memory invisible and the node advertised capacity it did not have.
func (c *Client) Capacity(ctx context.Context) (provider.Capacity, error) {
	var ns nodeStatus
	if err := c.doJSON(ctx, http.MethodGet, "/nodes/"+url.PathEscape(c.cfg.Node)+"/status", nil, &ns); err != nil {
		return provider.Capacity{}, err
	}

	// A failure to list one kind is non-fatal: we still report node totals and
	// whatever the other list gave. It does make the node look emptier than it
	// is, so the heartbeat that follows is the pessimistic case, not a silent
	// overstatement of a whole node.
	guests := make([]guestEntry, 0, 8)
	for _, kind := range []string{"qemu", "lxc"} {
		var gl guestList
		path := "/nodes/" + url.PathEscape(c.cfg.Node) + "/" + kind
		if err := c.doJSON(ctx, http.MethodGet, path, nil, &gl); err != nil {
			continue
		}
		guests = append(guests, gl.Data...)
	}
	if err := c.magBridgeGebruiken(ctx); err != nil {
		return provider.Capacity{}, err
	}
	return parseCapacity(ns, guests, c.oversubscribe()), nil
}

// magBridgeGebruiken controleert of het API-token een kaart aan de ingestelde
// bridge mag hangen.
//
// Sinds Proxmox 8.1 valt een gewone Linux-bridge onder de SDN-rechten. Een token
// met alle VM-rechten van de wereld maar zonder SDN.Use op
// /sdn/zones/localnetwork krijgt bij het klonen een 403 -- en dat is het eerste
// moment waarop iemand het merkt, want inschrijven en capaciteit melden gaan
// gewoon door. De node staat dan groen, de scheduler kiest hem, en de klant die
// besteld heeft krijgt de storing.
//
// Liever hier: dit maakt de node rood met de reden erbij, zoals elke andere
// hypervisor die iets niet kan. Het kost een GET per capaciteitsronde en het
// antwoord verandert zodra het recht wordt toegekend, dus het herstelt zichzelf
// zonder herstart.
func (c *Client) magBridgeGebruiken(ctx context.Context) error {
	bridge, _ := c.netwerk()
	if !safeBridge(bridge) {
		// Geen bridge afgedwongen: de kaart komt van de template en dit recht
		// speelt geen rol.
		return nil
	}

	pad := "/sdn/zones/localnetwork/" + bridge
	var out struct {
		Data map[string]map[string]int `json:"data"`
	}
	if err := c.doJSON(ctx, http.MethodGet, "/access/permissions?path="+url.QueryEscape(pad), nil, &out); err != nil {
		// Niet kunnen kijken is geen bewijs van niet mogen. Oudere versies
		// kennen dit pad niet, en daar bestaat het recht ook niet.
		return nil //nolint:nilerr // zie hierboven
	}
	for _, rechten := range out.Data {
		if rechten["SDN.Use"] == 1 {
			return nil
		}
	}
	// Kort genoeg om heel in het paneel te belanden: het control plane kapt een
	// reden af, en juist het commando is het deel dat iemand nodig heeft. Twee
	// dingen die uit de praktijk kwamen toen iemand hiermee vastliep:
	//
	// Er stond `--tokens JOUW-TOKEN-ID`, en dat is een commando dat je niet kunt
	// plakken -- je moet eerst ergens anders gaan zoeken, en dat is precies het
	// moment waarop iemand afhaakt. De regel zoekt het id nu zelf op, en werkt
	// of de node nu via de installer (bunk-worker) of met de hand (bunk-agent)
	// is opgezet.
	//
	// En er werd een eigen rol aangemaakt terwijl Proxmox `PVESDNUser` al
	// meelevert, met precies SDN.Audit en SDN.Use. Een tweede rol die hetzelfde
	// doet is een tweede ding dat op elke node apart bestaat en bij een upgrade
	// uit de pas kan gaan lopen.
	//
	// Het geheel past binnen de 240 tekens die een capaciteitsreden mag zijn, en
	// dat is geen toeval: bij de vorige versie sneuvelde juist het commando.
	return fmt.Errorf(
		"proxmox: bridge %s mag niet van dit token (SDN.Use ontbreekt). Als root op de host: "+
			"pveum acl modify /sdn/zones/localnetwork --roles PVESDNUser --tokens "+
			"$(grep -h TOKEN_ID /etc/bunk-*/agent.env|cut -d= -f2)",
		bridge)
}

// --- Lifecycle ------------------------------------------------------------

// taskResponse is the standard PVE "UPID" wrapper returned by async ops.
type taskResponse struct {
	Data string `json:"data"`
}

// taskStatus mirrors GET /nodes/{node}/tasks/{upid}/status. While a task runs,
// Status is "running"; once finished it is "stopped" and ExitStatus carries the
// outcome ("OK" on success, otherwise an error string).
type taskStatus struct {
	Data struct {
		Status     string `json:"status"`
		ExitStatus string `json:"exitstatus"`
	} `json:"data"`
}

// taskPollInterval is how often waitTask re-checks an in-flight UPID.
const taskPollInterval = 2 * time.Second

// taskState is the distilled outcome of a single task-status poll, split out so
// the decision logic can be unit-tested without a live PVE.
type taskState int

const (
	taskRunning taskState = iota // still in progress; keep polling
	taskOK                       // finished successfully (stopped + exitstatus OK)
	taskFailed                   // finished with a non-OK exit status
)

// evalTaskStatus interprets a decoded task-status body. When the task has
// failed it also returns the raw exit-status string for diagnostics.
func evalTaskStatus(ts taskStatus) (taskState, string) {
	if ts.Data.Status != "stopped" {
		return taskRunning, ""
	}
	if strings.EqualFold(strings.TrimSpace(ts.Data.ExitStatus), "OK") {
		return taskOK, ""
	}
	return taskFailed, ts.Data.ExitStatus
}

// waitTask polls a PVE worker task (identified by its UPID) until it reaches a
// terminal state or ctx is cancelled. It returns nil on a successful ("OK")
// exit status and an error otherwise.
func (c *Client) waitTask(ctx context.Context, upid string) error {
	upid = strings.TrimSpace(upid)
	if upid == "" {
		return errors.New("proxmox: waitTask called with empty UPID")
	}
	node := url.PathEscape(c.cfg.Node)
	statusPath := fmt.Sprintf("/nodes/%s/tasks/%s/status", node, url.PathEscape(upid))

	for {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("proxmox: wait for task %s: %w", upid, err)
		}

		var ts taskStatus
		if err := c.doJSON(ctx, http.MethodGet, statusPath, nil, &ts); err != nil {
			return fmt.Errorf("proxmox: poll task %s: %w", upid, err)
		}

		switch state, exit := evalTaskStatus(ts); state {
		case taskOK:
			return nil
		case taskFailed:
			return fmt.Errorf("proxmox: task %s failed: exitstatus %q", upid, exit)
		default:
			// still running; wait before the next poll, honouring cancellation.
			select {
			case <-ctx.Done():
				return fmt.Errorf("proxmox: wait for task %s: %w", upid, ctx.Err())
			case <-time.After(taskPollInterval):
			}
		}
	}
}

// nextVMID picks the id for a new guest.
//
// With a configured range it takes the lowest free id inside it, so Bunk stays
// out of the numbering the operator keeps for their own machines. Without one it
// falls back to the cluster's own answer, which is the lowest free id anywhere --
// fine on a machine that only does Bunk, and exactly wrong on one that does not.
func (c *Client) nextVMID(ctx context.Context) (int, error) {
	if min, max := c.vmidRange(); min > 0 && max >= min {
		used, err := c.usedVMIDs(ctx)
		if err != nil {
			return 0, err
		}
		return firstFreeVMID(used, min, max)
	}

	var resp struct {
		Data string `json:"data"`
	}
	if err := c.doJSON(ctx, http.MethodGet, "/cluster/nextid", nil, &resp); err != nil {
		return 0, err
	}
	id, err := strconv.Atoi(strings.TrimSpace(resp.Data))
	if err != nil {
		return 0, fmt.Errorf("proxmox: unexpected nextid %q: %w", resp.Data, err)
	}
	return id, nil
}

// usedVMIDs lists the ids already taken, cluster-wide where the token may read
// that and node-local otherwise. A VMID must be unique across the cluster, so
// the cluster view is the correct one; the per-node fallback exists because a
// token scoped to one node still has to be able to create a VM.
func (c *Client) usedVMIDs(ctx context.Context) (map[int]bool, error) {
	used := make(map[int]bool, 32)

	var cluster guestList
	if err := c.doJSON(ctx, http.MethodGet, "/cluster/resources?type=vm", nil, &cluster); err == nil {
		for _, g := range cluster.Data {
			used[g.VMID] = true
		}
		return used, nil
	}

	var gezien bool
	for _, kind := range []string{"qemu", "lxc"} {
		var gl guestList
		path := "/nodes/" + url.PathEscape(c.cfg.Node) + "/" + kind
		if err := c.doJSON(ctx, http.MethodGet, path, nil, &gl); err != nil {
			continue
		}
		gezien = true
		for _, g := range gl.Data {
			used[g.VMID] = true
		}
	}

	// Niets kunnen lezen is iets anders dan "niets in gebruik". Doorgaan met een
	// lege verzameling zou het laagste nummer uit het bereik pakken en zo een
	// bestaande machine kunnen overschrijven.
	if !gezien {
		return nil, errors.New("proxmox: could not list existing guests to pick a vmid")
	}
	return used, nil
}

// firstFreeVMID returns the lowest id in [min, max] that is not in use. Pure so
// the picking can be tested without a live PVE.
func firstFreeVMID(used map[int]bool, min, max int) (int, error) {
	for id := min; id <= max; id++ {
		if !used[id] {
			return id, nil
		}
	}
	return 0, fmt.Errorf("proxmox: no free vmid left in the configured range %d-%d", min, max)
}

// CreateVM implements provider.Provider.
//
// The flow is: allocate a VMID, clone the template (waiting for the clone task
// to finish), grow the primary disk, push CPU/RAM and cloud-init configuration,
// then start the guest (waiting for the start task to finish). Each async PVE
// operation returns a UPID that is polled to completion via waitTask so failures
// surface as errors rather than being silently lost.
func (c *Client) CreateVM(ctx context.Context, spec provider.VMSpec) (provider.VMStatus, error) {
	if spec.TemplateID == 0 {
		return provider.VMStatus{}, errors.New("proxmox: CreateVM requires a non-zero TemplateID")
	}

	newID, err := c.nextVMID(ctx)
	if err != nil {
		return provider.VMStatus{}, err
	}

	node := url.PathEscape(c.cfg.Node)

	// 1. Clone the template into the new VMID, then wait for the clone task.
	cloneForm := url.Values{}
	cloneForm.Set("newid", strconv.Itoa(newID))
	cloneForm.Set("name", spec.Name)
	cloneForm.Set("full", "1")
	var cloneTask taskResponse
	clonePath := fmt.Sprintf("/nodes/%s/qemu/%d/clone", node, spec.TemplateID)
	if err := c.doJSON(ctx, http.MethodPost, clonePath, cloneForm, &cloneTask); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: clone template %d: %w", spec.TemplateID, err)
	}
	if err := c.waitTask(ctx, cloneTask.Data); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: clone template %d into %d: %w", spec.TemplateID, newID, err)
	}

	// From here the VM physically exists on the hypervisor. Any later failure
	// (resize/config/start) must NOT leave it orphaned: roll it back with a
	// best-effort delete on a DETACHED context (so a cancelled ctx still cleans
	// up). If even the rollback fails, surface the vm id so the control plane
	// can reconcile/delete it later instead of losing track of it entirely.
	status, err := c.configureAndStart(ctx, node, newID, spec)
	if err != nil {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		if derr := c.DeleteVM(cleanupCtx, strconv.Itoa(newID), spec.VPSID); derr != nil {
			return provider.VMStatus{ID: strconv.Itoa(newID), State: "error"},
				fmt.Errorf("%w (rollback of vm %d failed: %v)", err, newID, derr)
		}
		return provider.VMStatus{}, err
	}
	return status, nil
}

// configureAndStart performs the post-clone steps (resize, config, start) on an
// already-cloned VM. Separated out so CreateVM can roll the clone back on any
// failure here. Returns the running VM status on success.
func (c *Client) configureAndStart(ctx context.Context, node string, newID int, spec provider.VMSpec) (provider.VMStatus, error) {
	// 2. Grow the primary disk to the requested size. Modern PVE (7.2+/8.x)
	// returns a task UPID from resize; older PVE returns null. Await the task when
	// one is present, so a failed/locked resize (e.g. storage full, or lock
	// contention right after the clone) surfaces as an error instead of the VM
	// being configured, started, and reported "done" with the template disk size
	// — silently giving the customer less disk than they paid for.
	if spec.DiskGB > 0 {
		resizeForm := url.Values{}
		resizeForm.Set("disk", "scsi0")
		resizeForm.Set("size", strconv.Itoa(spec.DiskGB)+"G")
		resizePath := fmt.Sprintf("/nodes/%s/qemu/%d/resize", node, newID)
		var resizeTask taskResponse
		if err := c.doJSON(ctx, http.MethodPut, resizePath, resizeForm, &resizeTask); err != nil {
			return provider.VMStatus{}, fmt.Errorf("proxmox: resize disk on vm %d: %w", newID, err)
		}
		if upid := strings.TrimSpace(resizeTask.Data); upid != "" {
			if err := c.waitTask(ctx, upid); err != nil {
				return provider.VMStatus{}, fmt.Errorf("proxmox: resize disk on vm %d: %w", newID, err)
			}
		}
	}

	// 3. Configure CPU/RAM, cloud-init and networking. Config is synchronous.
	cfgForm := url.Values{}
	if spec.VCPU > 0 {
		cfgForm.Set("cores", strconv.Itoa(spec.VCPU))
	}
	if spec.RAMMB > 0 {
		cfgForm.Set("memory", strconv.Itoa(spec.RAMMB))
	}
	if len(spec.SSHKeys) > 0 {
		cfgForm.Set("sshkeys", encodeProxmoxSSHKeys(spec.SSHKeys))
	}
	if spec.IPConfig != "" {
		cfgForm.Set("ipconfig0", spec.IPConfig)
	}
	// Wie deze gast is, op de gast zelf. Een VMID wordt hergebruikt zodra een
	// machine weg is; deze regel is wat een latere delete laat zien of hij de
	// juiste machine te pakken heeft. Hij staat ook gewoon in het Proxmox-scherm,
	// wat een operator die door de lijst scrolt precies vertelt wat hij ziet.
	if spec.VPSID != "" {
		cfgForm.Set("description", eigenaarsregel(spec.VPSID))
	}
	if bridge, vlan := c.netwerk(); safeBridge(bridge) {
		// firewall=1 zet de Proxmox VM-firewall aan op deze kaart. Zonder deze
		// vlag doen alle regels en filters hieronder niets: Proxmox hangt de
		// filterketen per interface op aan precies deze optie.
		net0 := "virtio,bridge=" + bridge + ",firewall=1"
		if vlan > 0 && vlan <= 4094 {
			net0 += ",tag=" + strconv.Itoa(vlan)
		}
		if rate := proxmoxRate(spec.RateMbit); rate != "" {
			net0 += ",rate=" + rate
		}
		cfgForm.Set("net0", net0)
	}
	if user, ok := spec.CloudInit["user"]; ok {
		cfgForm.Set("ciuser", user)
	}
	if pass, ok := spec.CloudInit["password"]; ok {
		cfgForm.Set("cipassword", pass)
	}
	cfgPath := fmt.Sprintf("/nodes/%s/qemu/%d/config", node, newID)
	if err := c.doJSON(ctx, http.MethodPost, cfgPath, cfgForm, nil); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: configure vm %d: %w", newID, err)
	}

	// 3b. Isoleer deze gast van zijn buren voordat hij draait.
	//
	// Een mislukking hier stopt het uitrollen NIET. De datacenter-firewall staat
	// standaard uit in Proxmox, en zolang dat zo is doen deze instellingen niets
	// -- ze staan dan alvast goed voor het moment dat een operator hem aanzet.
	// Wél afbreken zou betekenen dat een node zonder ingeschakelde firewall geen
	// enkele VPS meer kan uitrollen, en dat is een grotere storing dan het gat
	// dat we hier dichten.
	if err := c.isoleerGast(ctx, node, newID, spec); err != nil {
		// Geen logger in deze laag; de fout reist mee naar de agent, die hem
		// logt zonder de uitrol te laten mislukken.
		_ = err
	}

	// 4. Start the guest and wait for the start task to complete.
	var startTask taskResponse
	startPath := fmt.Sprintf("/nodes/%s/qemu/%d/status/start", node, newID)
	if err := c.doJSON(ctx, http.MethodPost, startPath, url.Values{}, &startTask); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: start vm %d: %w", newID, err)
	}
	if err := c.waitTask(ctx, startTask.Data); err != nil {
		return provider.VMStatus{}, fmt.Errorf("proxmox: start vm %d: %w", newID, err)
	}

	return provider.VMStatus{
		ID:    strconv.Itoa(newID),
		State: "provisioning",
	}, nil
}

// isoleerGast zet de firewall van één gast zo dat hij niet bij zijn buren kan.
//
// Het probleem dat dit oplost: alle klant-VPSen hangen aan dezelfde bridge, dus
// hun onderlinge verkeer wordt op laag 2 geschakeld en komt nooit langs de
// FORWARD-keten van de node. iptables op de host ziet het niet eens. Een klant
// kan daardoor zijn buren bereiken, hun verkeer meelezen na een ARP-truc, en
// zich voordoen als de gateway.
//
// Drie instellingen, elk met een eigen reden:
//
//   - `enable=1` plus `policy_out=ACCEPT`: de firewall staat aan voor deze gast,
//     en uitgaand verkeer blijft toegestaan -- we willen isoleren, niet de
//     dienst uitzetten.
//   - `ipfilter=1`: de gast mag alleen pakketten versturen met zijn eigen
//     bronadres. Dat is wat ARP- en IP-spoofing onmogelijk maakt, en het is de
//     helft die het meest uitmaakt.
//   - een DROP-regel naar het klantsubnet, met de gateway uitgezonderd: verkeer
//     naar buiten loopt via de gateway en blijft werken, verkeer naar een buur
//     wordt weggegooid.
//
// Voor een QEMU-gast weet Proxmox het IP-adres niet (cloud-init zet het), dus
// het ipfilter-ipset moet expliciet gevuld worden met het adres dat het control
// plane heeft toegewezen. Zonder die stap zou `ipfilter` alles blokkeren.
func (c *Client) isoleerGast(ctx context.Context, node string, vmid int, spec provider.VMSpec) error {
	ip := ipUitIPConfig(spec.IPConfig)
	if ip == "" {
		// Zonder toegewezen adres is er niets te filteren op bron, en een leeg
		// ipset zou de gast volledig afsluiten.
		return fmt.Errorf("proxmox: geen ip in ipconfig voor vm %d; firewall niet ingericht", vmid)
	}

	base := fmt.Sprintf("/nodes/%s/qemu/%d/firewall", node, vmid)

	opts := url.Values{}
	opts.Set("enable", "1")
	opts.Set("ipfilter", "1")
	opts.Set("policy_in", "ACCEPT")
	opts.Set("policy_out", "ACCEPT")
	if err := c.doJSON(ctx, http.MethodPut, base+"/options", opts, nil); err != nil {
		return fmt.Errorf("proxmox: firewall options vm %d: %w", vmid, err)
	}

	// Het ipset dat ipfilter gebruikt, met alleen het eigen adres erin.
	ipset := url.Values{}
	ipset.Set("name", "ipfilter-net0")
	if err := c.doJSON(ctx, http.MethodPost, base+"/ipset", ipset, nil); err != nil {
		// Bestaat al is geen fout: dit draait ook bij een herhaalde uitrol.
		_ = err
	}
	entry := url.Values{}
	entry.Set("cidr", ip)
	if err := c.doJSON(ctx, http.MethodPost, base+"/ipset/ipfilter-net0", entry, nil); err != nil {
		return fmt.Errorf("proxmox: ipfilter vm %d: %w", vmid, err)
	}

	// Buurverkeer weg, gateway houden. Volgorde telt: Proxmox evalueert van
	// boven naar beneden, dus de ACCEPT voor de gateway moet vóór de DROP staan.
	if gw := gatewayUitIPConfig(spec.IPConfig); gw != "" {
		accept := url.Values{}
		accept.Set("type", "out")
		accept.Set("action", "ACCEPT")
		accept.Set("dest", gw)
		accept.Set("enable", "1")
		accept.Set("comment", "gateway blijft bereikbaar")
		if err := c.doJSON(ctx, http.MethodPost, base+"/rules", accept, nil); err != nil {
			return fmt.Errorf("proxmox: gateway-regel vm %d: %w", vmid, err)
		}
	}

	if net := subnetUitIPConfig(spec.IPConfig); net != "" {
		drop := url.Values{}
		drop.Set("type", "out")
		drop.Set("action", "DROP")
		drop.Set("dest", net)
		drop.Set("enable", "1")
		drop.Set("comment", "geen verkeer naar andere klanten")
		if err := c.doJSON(ctx, http.MethodPost, base+"/rules", drop, nil); err != nil {
			return fmt.Errorf("proxmox: isolatieregel vm %d: %w", vmid, err)
		}
	}

	return nil
}

// ipconfig0 heeft de vorm "ip=10.10.0.20/19,gw=10.10.0.1". Deze drie helpers
// halen eruit wat de firewall nodig heeft; ze geven "" bij iets onverwachts,
// zodat de aanroeper kan besluiten niets te doen in plaats van te gokken.
func ipUitIPConfig(cfg string) string {
	for _, deel := range strings.Split(cfg, ",") {
		if na, ok := strings.CutPrefix(strings.TrimSpace(deel), "ip="); ok {
			if adres, _, ok := strings.Cut(na, "/"); ok {
				return adres
			}
			return na
		}
	}
	return ""
}

func gatewayUitIPConfig(cfg string) string {
	for _, deel := range strings.Split(cfg, ",") {
		if na, ok := strings.CutPrefix(strings.TrimSpace(deel), "gw="); ok {
			return na
		}
	}
	return ""
}

// Het subnet waar de gast in zit, als CIDR. Dat is precies de verzameling
// buren: alles daarin is een andere klant of de gateway.
func subnetUitIPConfig(cfg string) string {
	for _, deel := range strings.Split(cfg, ",") {
		if na, ok := strings.CutPrefix(strings.TrimSpace(deel), "ip="); ok {
			adres, prefix, ok := strings.Cut(na, "/")
			if !ok {
				return ""
			}
			_, netwerk, err := net.ParseCIDR(adres + "/" + prefix)
			if err != nil {
				return ""
			}
			return netwerk.String()
		}
	}
	return ""
}

// parseVMID turns the control plane's vm id string into the integer Proxmox
// addresses guests by. It is the first thing every lifecycle call does: the id
// arrives over the wire and goes straight into a URL path, so anything that is
// not a plain number has to stop here rather than downstream.
func parseVMID(id string) (int, error) {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return 0, fmt.Errorf("proxmox: invalid vm id %q: %w", id, err)
	}
	return vmid, nil
}

// DeleteVM implements provider.Provider. It stops the guest (best effort) and
// then destroys it. A missing guest is treated as success.
func (c *Client) DeleteVM(ctx context.Context, id string, vpsID string) error {
	vmid, err := parseVMID(id)
	if err != nil {
		return err
	}
	node := url.PathEscape(c.cfg.Node)

	// Hoort deze gast bij de machine die we moeten verwijderen? Een VMID wordt
	// hergebruikt, en een verwijdering die opnieuw wordt afgeleverd nadat dat
	// nummer aan een andere klant is gegeven, zou diens machine slopen.
	//
	// Alleen weigeren bij een aantoonbaar ANDERE eigenaar. Staat er niets op de
	// gast -- een machine van voor deze controle -- dan is het nummer alles wat
	// we hebben, en dan doen we wat er gevraagd is.
	if vpsID != "" {
		if eigenaar, ok := c.eigenaarVan(ctx, vmid); ok && eigenaar != vpsID {
			return fmt.Errorf(
				"proxmox: vmid %d hoort bij vps %s en niet bij %s; niet verwijderd",
				vmid, eigenaar, vpsID)
		}
	}

	// A destroy on a running VM is rejected ("VM is running"). Stop it first
	// and WAIT for the stop task to finish before deleting.
	if status, _, err := c.currentState(ctx, vmid); err == nil && status != "stopped" {
		stopPath := fmt.Sprintf("/nodes/%s/qemu/%d/status/stop", node, vmid)
		var stopTask taskResponse
		if err := c.doJSON(ctx, http.MethodPost, stopPath, url.Values{}, &stopTask); err == nil {
			_ = c.waitTask(ctx, stopTask.Data)
		}
	}

	delPath := fmt.Sprintf("/nodes/%s/qemu/%d", node, vmid)
	var delTask taskResponse
	if err := c.doJSON(ctx, http.MethodDelete, delPath, nil, &delTask); err != nil {
		// Proxmox returns a non-2xx for an unknown VMID; surface other errors
		// but treat a clear "does not exist" as success.
		if strings.Contains(err.Error(), "does not exist") {
			return nil
		}
		return err
	}
	// Destroy is asynchronous: wait on the returned UPID so callers only see
	// success once the guest is actually gone.
	if err := c.waitTask(ctx, delTask.Data); err != nil {
		return fmt.Errorf("proxmox: destroy vm %d: %w", vmid, err)
	}
	return nil
}

// currentState reads the guest's lifecycle status and qmpstatus (the latter
// distinguishes a paused guest, whose status stays "running").
func (c *Client) currentState(ctx context.Context, vmid int) (status, qmp string, err error) {
	node := url.PathEscape(c.cfg.Node)
	path := fmt.Sprintf("/nodes/%s/qemu/%d/status/current", node, vmid)
	var cur vmCurrentStatus
	if err := c.doJSON(ctx, http.MethodGet, path, nil, &cur); err != nil {
		return "", "", err
	}
	return cur.Data.Status, cur.Data.QmpStatus, nil
}

// powerOp issues a status/{op} action and waits for the resulting task.
func (c *Client) powerOp(ctx context.Context, vmid int, op string) error {
	node := url.PathEscape(c.cfg.Node)
	path := fmt.Sprintf("/nodes/%s/qemu/%d/status/%s", node, vmid, op)
	var task taskResponse
	if err := c.doJSON(ctx, http.MethodPost, path, url.Values{}, &task); err != nil {
		return fmt.Errorf("proxmox: %s vm %d: %w", op, vmid, err)
	}
	if err := c.waitTask(ctx, task.Data); err != nil {
		return fmt.Errorf("proxmox: %s vm %d: %w", op, vmid, err)
	}
	return nil
}

// PowerOn implements provider.Provider; idempotent if the guest already runs.
func (c *Client) PowerOn(ctx context.Context, id string) error {
	vmid, err := parseVMID(id)
	if err != nil {
		return err
	}
	status, _, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if status == "running" {
		return nil
	}
	return c.powerOp(ctx, vmid, "start")
}

// ListGuestIDs implements provider.Provider. Het gebruikt dezelfde bron als de
// VMID-toewijzing, zodat "welke nummers zijn bezet" en "welke gasten draaien
// hier" nooit uit elkaar kunnen lopen.
func (c *Client) ListGuestIDs(ctx context.Context) ([]string, error) {
	used, err := c.usedVMIDs(ctx)
	if err != nil {
		return nil, fmt.Errorf("proxmox: list guests: %w", err)
	}

	ids := make([]string, 0, len(used))
	for vmid := range used {
		ids = append(ids, strconv.Itoa(vmid))
	}
	sort.Strings(ids)

	return ids, nil
}

// Reboot implements provider.Provider: Proxmox's own reboot, which is a clean
// shutdown followed by a start. It needs a guest that answers ACPI (the template
// ships with the qemu guest agent enabled), and it is not a reset -- a guest that
// ignores the request keeps running rather than losing its disk cache.
func (c *Client) Reboot(ctx context.Context, id string) error {
	vmid, err := parseVMID(id)
	if err != nil {
		return err
	}
	status, _, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if status != "running" {
		return fmt.Errorf("proxmox: vm %d is %s, not running: cannot reboot", vmid, status)
	}
	return c.powerOp(ctx, vmid, "reboot")
}

// PowerOff implements provider.Provider; idempotent if already stopped.
func (c *Client) PowerOff(ctx context.Context, id string) error {
	vmid, err := parseVMID(id)
	if err != nil {
		return err
	}
	status, _, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if status == "stopped" {
		return nil
	}
	return c.powerOp(ctx, vmid, "stop")
}

// Suspend implements provider.Provider (suspend-to-RAM); idempotent if paused.
func (c *Client) Suspend(ctx context.Context, id string) error {
	vmid, err := parseVMID(id)
	if err != nil {
		return err
	}
	status, qmp, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if qmp == "paused" {
		return nil
	}
	if status != "running" {
		return fmt.Errorf("proxmox: suspend vm %d: not running (status=%s)", vmid, status)
	}
	return c.powerOp(ctx, vmid, "suspend")
}

// Resume implements provider.Provider; idempotent if already running.
func (c *Client) Resume(ctx context.Context, id string) error {
	vmid, err := parseVMID(id)
	if err != nil {
		return err
	}
	status, qmp, err := c.currentState(ctx, vmid)
	if err != nil {
		return err
	}
	if status == "running" && qmp != "paused" {
		return nil
	}
	return c.powerOp(ctx, vmid, "resume")
}

// vmCurrentStatus mirrors GET /nodes/{node}/qemu/{id}/status/current.
type vmCurrentStatus struct {
	Data struct {
		Status    string `json:"status"`
		QmpStatus string `json:"qmpstatus"`
	} `json:"data"`
}

// vmAgentIfaces mirrors the QEMU guest-agent network-interface query.
type vmAgentIfaces struct {
	Data struct {
		Result []struct {
			Name    string `json:"name"`
			IPAddrs []struct {
				Type    string `json:"ip-address-type"`
				Address string `json:"ip-address"`
			} `json:"ip-addresses"`
		} `json:"result"`
	} `json:"data"`
}

// StatusVM implements provider.Provider. It reports lifecycle state and, when
// the guest agent is available, the primary non-loopback IPv4 address.
func (c *Client) StatusVM(ctx context.Context, id string) (provider.VMStatus, error) {
	vmid, err := parseVMID(id)
	if err != nil {
		return provider.VMStatus{}, err
	}
	node := url.PathEscape(c.cfg.Node)

	var cur vmCurrentStatus
	statusPath := fmt.Sprintf("/nodes/%s/qemu/%d/status/current", node, vmid)
	if err := c.doJSON(ctx, http.MethodGet, statusPath, nil, &cur); err != nil {
		return provider.VMStatus{}, err
	}

	st := provider.VMStatus{ID: id, State: cur.Data.Status}
	if st.State == "" {
		st.State = "unknown"
	}

	// Best-effort IP discovery via the guest agent; failures are ignored.
	var ifaces vmAgentIfaces
	agentPath := fmt.Sprintf("/nodes/%s/qemu/%d/agent/network-get-interfaces", node, vmid)
	if err := c.doJSON(ctx, http.MethodGet, agentPath, nil, &ifaces); err == nil {
		st.IP = firstIPv4(ifaces)
	}
	return st, nil
}

// findGuestByName scans a decoded guest list for an entry whose name matches
// name exactly and returns its VMID, status and whether a match was found. It is
// a pure helper, split out of FindByName so the name-matching logic can be
// unit-tested without a live PVE.
func findGuestByName(guests []guestEntry, name string) (vmid int, status string, found bool) {
	// An empty query never matches: a nameless guest must not be treated as a
	// match for an "unset" name (which would make idempotency dangerously broad).
	if name == "" {
		return 0, "", false
	}
	for _, g := range guests {
		if g.Name == name {
			return g.VMID, g.Status, true
		}
	}
	return 0, "", false
}

// FindByName implements provider.Provider. It lists the node's QEMU guests and
// returns the status of the one whose name matches name. The boolean is false
// (with a zero VMStatus) when no guest carries that name; a non-nil error means
// the list query itself failed.
func (c *Client) FindByName(ctx context.Context, name string) (provider.VMStatus, bool, error) {
	var gl guestList
	listPath := "/nodes/" + url.PathEscape(c.cfg.Node) + "/qemu"
	if err := c.doJSON(ctx, http.MethodGet, listPath, nil, &gl); err != nil {
		return provider.VMStatus{}, false, fmt.Errorf("proxmox: list guests for name %q: %w", name, err)
	}

	vmid, status, found := findGuestByName(gl.Data, name)
	if !found {
		return provider.VMStatus{}, false, nil
	}
	if status == "" {
		status = "unknown"
	}
	return provider.VMStatus{ID: strconv.Itoa(vmid), State: status}, true, nil
}

// firstIPv4 returns the first non-loopback IPv4 address from a guest-agent
// interface listing, or "" if none is found.
func firstIPv4(ifaces vmAgentIfaces) string {
	for _, ifc := range ifaces.Data.Result {
		for _, addr := range ifc.IPAddrs {
			if addr.Type == "ipv4" && addr.Address != "" && !strings.HasPrefix(addr.Address, "127.") {
				return addr.Address
			}
		}
	}
	return ""
}

// encodeProxmoxSSHKeys renders SSH public keys for Proxmox's `sshkeys` config
// parameter. PVE expects the value RFC3986 percent-encoded and rejects the
// form-style '+' that url.QueryEscape emits for spaces, so spaces are rewritten
// to %20. The HTTP form encoder then double-encodes this, which PVE unwinds (it
// form-decodes the body once, then percent-decodes the sshkeys value once),
// recovering the original keys. Trailing whitespace is trimmed so a stray
// newline can't trip PVE's "Parameter verification failed" check.
func encodeProxmoxSSHKeys(keys []string) string {
	joined := strings.TrimSpace(strings.Join(keys, "\n"))
	return strings.ReplaceAll(url.QueryEscape(joined), "+", "%20")
}

// proxmoxRate vertaalt de snelheid van het pakket naar wat Proxmox op `net0`
// verwacht. Wij rekenen in megabit per seconde, want dat is wat een klant koopt;
// Proxmox rekent in MEGABYTE per seconde. Acht keer verschil, en het is precies
// het soort verschil dat je pas ontdekt als iemand klaagt dat zijn 1 Gbit-pakket
// 125 megabit doet.
//
// Lege string bij nul of negatief: geen limiet. Een VPS zonder pakket hoort geen
// verzonnen rem te krijgen.
//
// De waarde gaat met één decimaal mee, want 500 Mbit is 62,5 MB/s en afronden
// naar 62 of 63 is een halve procent die niemand hoeft te cadeau te krijgen of
// kwijt te raken.
func proxmoxRate(mbit int) string {
	if mbit <= 0 {
		return ""
	}
	return strconv.FormatFloat(float64(mbit)/8.0, 'f', -1, 64)
}

// eigenaarsregel is wat er in de beschrijving van de gast komt te staan. Eén
// regel, herkenbaar, en met de id waar het om gaat.
func eigenaarsregel(vpsID string) string {
	return "bunk-vps: " + vpsID
}

// eigenaarVan leest terug welke VPS op deze gast is gezet. `ok` is false als er
// niets staat, als de gast niet bestaat, of als de API niet te bereiken is --
// alle drie zijn "ik weet het niet", en daarop weigeren we niets.
func (c *Client) eigenaarVan(ctx context.Context, vmid int) (string, bool) {
	var resp struct {
		Data struct {
			Description string `json:"description"`
		} `json:"data"`
	}

	path := fmt.Sprintf("/nodes/%s/qemu/%d/config", url.PathEscape(c.cfg.Node), vmid)
	if err := c.doJSON(ctx, http.MethodGet, path, nil, &resp); err != nil {
		return "", false
	}

	for _, regel := range strings.Split(resp.Data.Description, "\n") {
		regel = strings.TrimSpace(regel)
		if rest, gevonden := strings.CutPrefix(regel, "bunk-vps:"); gevonden {
			return strings.TrimSpace(rest), true
		}
	}
	return "", false
}
