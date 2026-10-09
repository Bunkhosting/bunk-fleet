package proxmox

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

// The driver's pure helpers are covered elsewhere; what is exercised here is the
// part that talks to Proxmox — the request it builds, the task it waits for, and
// what it does when a step fails halfway through. That matters more than the
// helpers: this code destroys customer machines.

// recorder is a stand-in PVE API. Handlers are keyed by "METHOD /path"; every
// request is recorded so a test can assert on what was actually sent.
type recorder struct {
	mu       sync.Mutex
	requests []recorded
	handlers map[string]http.HandlerFunc
	srv      *httptest.Server
}

type recorded struct {
	method string
	path   string
	form   url.Values
	auth   string
}

func newRecorder(t *testing.T) *recorder {
	t.Helper()
	r := &recorder{handlers: map[string]http.HandlerFunc{}}

	r.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		_ = req.ParseForm()
		path := strings.TrimPrefix(req.URL.Path, "/api2/json")

		r.mu.Lock()
		r.requests = append(r.requests, recorded{
			method: req.Method,
			path:   path,
			form:   req.PostForm,
			auth:   req.Header.Get("Authorization"),
		})
		handler, ok := r.handlers[req.Method+" "+path]
		r.mu.Unlock()

		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"errors":"no such endpoint"}`))
			return
		}
		handler(w, req)
	}))

	t.Cleanup(r.srv.Close)
	return r
}

func (r *recorder) on(route string, body string) {
	r.handlers[route] = func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(body))
	}
}

func (r *recorder) onStatus(route string, status int, body string) {
	r.handlers[route] = func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}
}

func (r *recorder) seen(method, path string) (recorded, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, req := range r.requests {
		if req.method == method && req.path == path {
			return req, true
		}
	}
	return recorded{}, false
}

func (r *recorder) count(method, path string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, req := range r.requests {
		if req.method == method && req.path == path {
			n++
		}
	}
	return n
}

func (r *recorder) client(t *testing.T, mutate ...func(*Config)) *Client {
	t.Helper()
	cfg := Config{
		Host:        r.srv.URL,
		Node:        "pve",
		TokenID:     "root@pam!agent",
		TokenSecret: "secret-value",
		VerifySSL:   false,
	}
	for _, m := range mutate {
		m(&cfg)
	}
	c, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	c.http = r.srv.Client()
	return c
}

// A UPID that the recorder resolves to a finished, successful task.
const okTask = `{"data":"UPID:pve:0000:OK::task"}`

// firewallVoor laat de vier aanroepen van isoleerGast slagen voor één gast.
func (r *recorder) firewallVoor(vmid string) {
	base := "/nodes/pve/qemu/" + vmid + "/firewall"
	r.on("PUT "+base+"/options", `{"data":null}`)
	r.on("POST "+base+"/ipset", `{"data":null}`)
	r.on("POST "+base+"/ipset/ipfilter-net0", `{"data":null}`)
	r.on("POST "+base+"/rules", `{"data":null}`)
}

func (r *recorder) taskSucceeds() {
	r.on("GET /nodes/pve/tasks/UPID:pve:0000:OK::task/status",
		`{"data":{"status":"stopped","exitstatus":"OK"}}`)
}

func (r *recorder) taskFails(reason string) {
	r.on("GET /nodes/pve/tasks/UPID:pve:0000:OK::task/status",
		fmt.Sprintf(`{"data":{"status":"stopped","exitstatus":%q}}`, reason))
}

func TestCreateVMHappyPath(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /cluster/nextid", `{"data":"131"}`)
	r.on("POST /nodes/pve/qemu/9000/clone", okTask)
	r.on("PUT /nodes/pve/qemu/131/resize", okTask)
	r.on("POST /nodes/pve/qemu/131/config", `{"data":null}`)
	r.firewallVoor("131")
	r.on("POST /nodes/pve/qemu/131/status/start", okTask)
	r.taskSucceeds()

	c := r.client(t, func(cfg *Config) { cfg.Bridge = "vmbr1"; cfg.VLAN = 42 })

	got, err := c.CreateVM(context.Background(), provider.VMSpec{
		Name:       "web-1",
		TemplateID: 9000,
		VCPU:       2,
		RAMMB:      2048,
		DiskGB:     40,
		SSHKeys:    []string{"ssh-ed25519 AAAA test@host"},
		IPConfig:   "ip=10.10.0.21/22,gw=10.10.0.1",
		CloudInit:  map[string]string{"user": "bunk", "password": "pw"},
	})
	if err != nil {
		t.Fatalf("CreateVM: %v", err)
	}
	if got.ID != "131" || got.State != "provisioning" {
		t.Fatalf("CreateVM = %+v, want id 131 provisioning", got)
	}

	clone, ok := r.seen("POST", "/nodes/pve/qemu/9000/clone")
	if !ok {
		t.Fatal("the template was never cloned")
	}
	// A linked clone shares the template's disk: deleting the template would take
	// the customer's machine with it.
	if clone.form.Get("full") != "1" {
		t.Errorf("clone full = %q, want 1", clone.form.Get("full"))
	}
	if clone.form.Get("newid") != "131" {
		t.Errorf("clone newid = %q, want 131", clone.form.Get("newid"))
	}
	if clone.auth != "PVEAPIToken=root@pam!agent=secret-value" {
		t.Errorf("Authorization = %q", clone.auth)
	}

	resize, _ := r.seen("PUT", "/nodes/pve/qemu/131/resize")
	if resize.form.Get("size") != "40G" || resize.form.Get("disk") != "scsi0" {
		t.Errorf("resize = %v, want scsi0 40G", resize.form)
	}

	cfg, _ := r.seen("POST", "/nodes/pve/qemu/131/config")
	for field, want := range map[string]string{
		"cores":     "2",
		"memory":    "2048",
		"ipconfig0": "ip=10.10.0.21/22,gw=10.10.0.1",
		// firewall=1 hoort erbij: zonder die vlag hangt Proxmox geen
		// filterketen aan deze interface en doen ipfilter en de
		// isolatieregels niets. Zie isoleerGast.
		// Geen rate= erin: deze spec heeft geen RateMbit, en dan hoort er geen
		// limiet op de kaart te komen. Zie TestCreateVMZetDeSnelheidVanHetPakket.
		"net0":       "virtio,bridge=vmbr1,firewall=1,tag=42",
		"ciuser":     "bunk",
		"cipassword": "pw",
	} {
		if cfg.form.Get(field) != want {
			t.Errorf("config %s = %q, want %q", field, cfg.form.Get(field), want)
		}
	}
}

// De snelheid die bij het pakket hoort, komt als `rate=` op de netwerkkaart van
// de gast. Dat is de enige plek waar die belofte wordt waargemaakt: zonder deze
// regel is "tot 500 Mbit" een zin op een pagina.
func TestCreateVMZetDeSnelheidVanHetPakket(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /cluster/nextid", `{"data":"131"}`)
	r.on("POST /nodes/pve/qemu/9000/clone", okTask)
	r.on("PUT /nodes/pve/qemu/131/resize", okTask)
	r.on("POST /nodes/pve/qemu/131/config", `{"data":null}`)
	r.on("POST /nodes/pve/qemu/131/status/start", okTask)
	r.taskSucceeds()

	c := r.client(t, func(cfg *Config) { cfg.Bridge = "vmbr1" })

	if _, err := c.CreateVM(context.Background(), provider.VMSpec{
		Name:       "web-1",
		TemplateID: 9000,
		VCPU:       2,
		RAMMB:      2048,
		DiskGB:     40,
		// Basic: 500 Mbit. Voor Proxmox is dat 62,5 MB/s -- geen heel getal, en
		// afronden zou een halve procent weggeven of afpakken.
		RateMbit: 500,
	}); err != nil {
		t.Fatalf("CreateVM: %v", err)
	}

	cfg, _ := r.seen("POST", "/nodes/pve/qemu/131/config")
	if got, want := cfg.form.Get("net0"), "virtio,bridge=vmbr1,firewall=1,rate=62.5"; got != want {
		t.Errorf("net0 = %q, want %q", got, want)
	}
}

func TestCreateVMRollsBackAfterTheCloneSucceeds(t *testing.T) {
	// Once the clone lands the VM physically exists. A failure after that point
	// must not leave it running on the node, unbilled and unreachable.
	r := newRecorder(t)
	r.on("GET /cluster/nextid", `{"data":"140"}`)
	r.on("POST /nodes/pve/qemu/9000/clone", okTask)
	r.onStatus("PUT /nodes/pve/qemu/140/resize", http.StatusInternalServerError, `{"errors":"storage full"}`)
	r.on("GET /nodes/pve/qemu/140/status/current", `{"data":{"status":"stopped"}}`)
	r.on("DELETE /nodes/pve/qemu/140", okTask)
	r.taskSucceeds()

	c := r.client(t)

	_, err := c.CreateVM(context.Background(), provider.VMSpec{Name: "x", TemplateID: 9000, DiskGB: 40})
	if err == nil {
		t.Fatal("CreateVM returned no error after the resize failed")
	}
	if r.count("DELETE", "/nodes/pve/qemu/140") != 1 {
		t.Error("the half-created VM was not rolled back")
	}
}

func TestCreateVMSurfacesTheIDWhenRollbackAlsoFails(t *testing.T) {
	// If even the cleanup fails, the vm id has to come back in the status so the
	// control plane can reconcile it later rather than losing track of it.
	r := newRecorder(t)
	r.on("GET /cluster/nextid", `{"data":"141"}`)
	r.on("POST /nodes/pve/qemu/9000/clone", okTask)
	r.onStatus("POST /nodes/pve/qemu/141/config", http.StatusBadRequest, `{"errors":"bad"}`)
	r.on("GET /nodes/pve/qemu/141/status/current", `{"data":{"status":"stopped"}}`)
	r.onStatus("DELETE /nodes/pve/qemu/141", http.StatusInternalServerError, `{"errors":"locked"}`)
	r.taskSucceeds()

	c := r.client(t)

	got, err := c.CreateVM(context.Background(), provider.VMSpec{Name: "x", TemplateID: 9000})
	if err == nil {
		t.Fatal("CreateVM returned no error")
	}
	if got.ID != "141" {
		t.Errorf("status ID = %q, want 141 so the orphan can be reconciled", got.ID)
	}
	if !strings.Contains(err.Error(), "rollback") {
		t.Errorf("error does not mention the failed rollback: %v", err)
	}
}

func TestCreateVMRefusesWithoutATemplate(t *testing.T) {
	r := newRecorder(t)
	c := r.client(t)

	if _, err := c.CreateVM(context.Background(), provider.VMSpec{Name: "x"}); err == nil {
		t.Fatal("CreateVM accepted a zero TemplateID")
	}
	if len(r.requests) != 0 {
		t.Errorf("it talked to Proxmox anyway: %v", r.requests)
	}
}

func TestCreateVMFailsWhenTheCloneTaskFails(t *testing.T) {
	// The task returns a UPID immediately; only polling it reveals the failure.
	// Treating the 200 as success would report a VM that does not exist.
	r := newRecorder(t)
	r.on("GET /cluster/nextid", `{"data":"150"}`)
	r.on("POST /nodes/pve/qemu/9000/clone", okTask)
	r.taskFails("clone failed: no space left on device")

	c := r.client(t)

	_, err := c.CreateVM(context.Background(), provider.VMSpec{Name: "x", TemplateID: 9000})
	if err == nil {
		t.Fatal("a failed clone task was reported as success")
	}
	if !strings.Contains(err.Error(), "no space left") {
		t.Errorf("the reason was lost: %v", err)
	}
}

func TestDeleteVMStopsARunningGuestFirst(t *testing.T) {
	// Proxmox refuses to destroy a running VM. Skipping the stop leaves the
	// customer's machine alive and the control plane believing it is gone.
	r := newRecorder(t)
	r.on("GET /nodes/pve/qemu/131/status/current", `{"data":{"status":"running"}}`)
	r.on("POST /nodes/pve/qemu/131/status/stop", okTask)
	r.on("DELETE /nodes/pve/qemu/131", okTask)
	r.taskSucceeds()

	if err := r.client(t).DeleteVM(context.Background(), "131", ""); err != nil {
		t.Fatalf("DeleteVM: %v", err)
	}
	if r.count("POST", "/nodes/pve/qemu/131/status/stop") != 1 {
		t.Error("the running guest was not stopped before the destroy")
	}
}

func TestDeleteVMSkipsTheStopWhenAlreadyStopped(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /nodes/pve/qemu/131/status/current", `{"data":{"status":"stopped"}}`)
	r.on("DELETE /nodes/pve/qemu/131", okTask)
	r.taskSucceeds()

	if err := r.client(t).DeleteVM(context.Background(), "131", ""); err != nil {
		t.Fatalf("DeleteVM: %v", err)
	}
	if r.count("POST", "/nodes/pve/qemu/131/status/stop") != 0 {
		t.Error("it stopped a guest that was already stopped")
	}
}

func TestDeleteVMTreatsAMissingGuestAsDone(t *testing.T) {
	// Delete commands are re-delivered. The second one finds nothing and must
	// still report success, or the VPS never leaves :deleting.
	r := newRecorder(t)
	r.onStatus("GET /nodes/pve/qemu/999/status/current", http.StatusInternalServerError,
		`{"errors":"Configuration file 'nodes/pve/qemu-server/999.conf' does not exist"}`)
	r.onStatus("DELETE /nodes/pve/qemu/999", http.StatusInternalServerError,
		`{"errors":"Configuration file 'nodes/pve/qemu-server/999.conf' does not exist"}`)

	if err := r.client(t).DeleteVM(context.Background(), "999", ""); err != nil {
		t.Fatalf("DeleteVM on a missing guest = %v, want nil", err)
	}
}

// Een VMID wordt hergebruikt zodra een machine weg is. Wordt een verwijdering
// opnieuw afgeleverd nadat dat nummer aan een andere klant is gegeven -- en dat
// gebeurt, want het control plane levert opnieuw af als het geen resultaat kreeg
// -- dan zou zonder deze controle de machine van die ander gesloopt worden.
func TestDeleteVMWeigertEenGastVanIemandAnders(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /nodes/pve/qemu/131/config", `{"data":{"description":"bunk-vps: 11111111-1111-1111-1111-111111111111"}}`)

	err := r.client(t).DeleteVM(context.Background(), "131",
		"22222222-2222-2222-2222-222222222222")
	if err == nil {
		t.Fatal("een gast van een andere vps is verwijderd")
	}
	if !strings.Contains(err.Error(), "niet verwijderd") {
		t.Errorf("de fout zegt niet wat er is gebeurd: %v", err)
	}
	if _, geprobeerd := r.seen("DELETE", "/nodes/pve/qemu/131"); geprobeerd {
		t.Error("er is alsnog een destroy gestuurd")
	}
}

func TestDeleteVMVerwijdertZijnEigenGast(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /nodes/pve/qemu/131/config", `{"data":{"description":"bunk-vps: 11111111-1111-1111-1111-111111111111"}}`)
	r.on("GET /nodes/pve/qemu/131/status/current", `{"data":{"status":"stopped"}}`)
	r.on("DELETE /nodes/pve/qemu/131", okTask)
	r.taskSucceeds()

	if err := r.client(t).DeleteVM(context.Background(), "131",
		"11111111-1111-1111-1111-111111111111"); err != nil {
		t.Fatalf("DeleteVM: %v", err)
	}
}

// Een gast van vóór deze controle draagt geen id. Dan is het nummer alles wat we
// hebben, en weigeren zou betekenen dat oude machines niet meer weg kunnen.
func TestDeleteVMGaatDoorZonderIdOpDeGast(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /nodes/pve/qemu/131/config", `{"data":{"description":""}}`)
	r.on("GET /nodes/pve/qemu/131/status/current", `{"data":{"status":"stopped"}}`)
	r.on("DELETE /nodes/pve/qemu/131", okTask)
	r.taskSucceeds()

	if err := r.client(t).DeleteVM(context.Background(), "131", "iets"); err != nil {
		t.Fatalf("DeleteVM: %v", err)
	}
}

func TestDeleteVMRefusesANonNumericID(t *testing.T) {
	r := newRecorder(t)

	if err := r.client(t).DeleteVM(context.Background(), "131/../../etc", ""); err == nil {
		t.Fatal("DeleteVM accepted a non-numeric id")
	}
	if len(r.requests) != 0 {
		t.Errorf("it built a request out of it: %v", r.requests)
	}
}

func TestDeleteVMFailsWhenTheDestroyTaskFails(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /nodes/pve/qemu/131/status/current", `{"data":{"status":"stopped"}}`)
	r.on("DELETE /nodes/pve/qemu/131", okTask)
	r.taskFails("destroy failed: volume in use")

	if err := r.client(t).DeleteVM(context.Background(), "131", ""); err == nil {
		t.Fatal("a failed destroy task was reported as success")
	}
}

func TestDoJSONReportsTheBodyOnAnErrorStatus(t *testing.T) {
	// The agent hands this string to the control plane, which shows it to an
	// operator. A bare "status 500" is not something anyone can act on.
	r := newRecorder(t)
	r.onStatus("GET /cluster/nextid", http.StatusForbidden, `{"errors":"permission denied"}`)

	_, err := r.client(t).CreateVM(context.Background(), provider.VMSpec{Name: "x", TemplateID: 9000})
	if err == nil || !strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("error = %v, want it to carry the PVE message", err)
	}
}

func TestCancelledContextStopsTheTaskPoll(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /cluster/nextid", `{"data":"160"}`)
	r.on("POST /nodes/pve/qemu/9000/clone", okTask)
	// Never finishes: without honouring cancellation this poll runs forever.
	r.on("GET /nodes/pve/tasks/UPID:pve:0000:OK::task/status", `{"data":{"status":"running"}}`)

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	_, err := r.client(t).CreateVM(ctx, provider.VMSpec{Name: "x", TemplateID: 9000})
	if err == nil {
		t.Fatal("a cancelled context did not stop the create")
	}
}

func TestNewRefusesAnIncompleteConfig(t *testing.T) {
	for name, cfg := range map[string]Config{
		"no host":   {Node: "pve", TokenID: "a", TokenSecret: "b"},
		"no node":   {Host: "https://x", TokenID: "a", TokenSecret: "b"},
		"no token":  {Host: "https://x", Node: "pve", TokenSecret: "b"},
		"no secret": {Host: "https://x", Node: "pve", TokenID: "a"},
	} {
		if _, err := New(cfg); err == nil {
			t.Errorf("New accepted a config with %s", name)
		}
	}
}

func TestBaseURLToleratesATrailingSlash(t *testing.T) {
	c, err := New(Config{Host: "https://pve.example:8006/", Node: "pve", TokenID: "a", TokenSecret: "b"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if c.base != "https://pve.example:8006/api2/json" {
		t.Errorf("base = %q", c.base)
	}
}

// Proxmox zet een nieuwe regel bovenaan en leest van boven naar beneden. De
// gateway-ACCEPT moet dus ná de DROP worden aangemaakt, anders staat de DROP
// bovenaan en snijdt hij -- zodra iemand de datacenter-firewall aanzet -- elke
// VPS af van zijn gateway. Zo stond het op productie.
func TestIsolatieLaatDeGatewayBovenDeDropStaan(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /cluster/nextid", `{"data":"131"}`)
	r.on("POST /nodes/pve/qemu/9000/clone", okTask)
	r.on("PUT /nodes/pve/qemu/131/resize", okTask)
	r.on("POST /nodes/pve/qemu/131/config", `{"data":null}`)
	r.firewallVoor("131")
	r.on("POST /nodes/pve/qemu/131/status/start", okTask)
	r.taskSucceeds()

	if _, err := r.client(t).CreateVM(context.Background(), provider.VMSpec{
		Name: "x", TemplateID: 9000, DiskGB: 40, IPConfig: "ip=10.10.0.21/22,gw=10.10.0.1",
	}); err != nil {
		t.Fatalf("CreateVM: %v", err)
	}

	var regels []url.Values
	r.mu.Lock()
	for _, req := range r.requests {
		if req.method == "POST" && req.path == "/nodes/pve/qemu/131/firewall/rules" {
			regels = append(regels, req.form)
		}
	}
	r.mu.Unlock()

	if len(regels) != 2 {
		t.Fatalf("%d regels aangemaakt, wilde er 2", len(regels))
	}
	if regels[0].Get("action") != "DROP" || regels[1].Get("action") != "ACCEPT" {
		t.Fatalf("volgorde van aanmaken: %s dan %s; de ACCEPT moet als laatste, zodat hij bovenaan komt",
			regels[0].Get("action"), regels[1].Get("action"))
	}
	if regels[1].Get("dest") != "10.10.0.1" || regels[0].Get("dest") != "10.10.0.0/22" {
		t.Errorf("doelen: drop %q, accept %q", regels[0].Get("dest"), regels[1].Get("dest"))
	}
	for _, f := range regels {
		if f.Get("pos") != "0" {
			t.Errorf("regel %s zonder pos=0", f.Get("action"))
		}
	}
}

// Een gast waarvan de afscherming mislukte, mag niet starten. Eerst werd die
// fout weggegooid en startte hij open naar zijn buren.
func TestMisluktIsolerenDraaitDeGastTerug(t *testing.T) {
	r := newRecorder(t)
	r.on("GET /cluster/nextid", `{"data":"132"}`)
	r.on("POST /nodes/pve/qemu/9000/clone", okTask)
	r.on("PUT /nodes/pve/qemu/132/resize", okTask)
	r.on("POST /nodes/pve/qemu/132/config", `{"data":null}`)
	r.onStatus("PUT /nodes/pve/qemu/132/firewall/options", http.StatusForbidden, `{"errors":"permission denied"}`)
	r.on("POST /nodes/pve/qemu/132/status/start", okTask)
	r.on("GET /nodes/pve/qemu/132/status/current", `{"data":{"status":"stopped"}}`)
	r.on("DELETE /nodes/pve/qemu/132", okTask)
	r.taskSucceeds()

	_, err := r.client(t).CreateVM(context.Background(), provider.VMSpec{
		Name: "x", TemplateID: 9000, DiskGB: 40, IPConfig: "ip=10.10.0.22/22,gw=10.10.0.1",
	})
	if err == nil {
		t.Fatal("CreateVM slaagde terwijl de afscherming mislukte")
	}
	if r.count("POST", "/nodes/pve/qemu/132/status/start") != 0 {
		t.Error("de gast is gestart zonder afscherming")
	}
	if r.count("DELETE", "/nodes/pve/qemu/132") != 1 {
		t.Error("de half aangemaakte gast is niet teruggedraaid")
	}
}

func TestAfschermingMeldtEenUitgeschakeldeDatacenterFirewall(t *testing.T) {
	for _, tc := range []struct {
		naam, antwoord string
		melding        bool
	}{
		{"nooit ingesteld (de Proxmox-standaard)", `{"data":{"digest":"x"}}`, true},
		{"uitgezet", `{"data":{"enable":0}}`, true},
		{"aan", `{"data":{"enable":1}}`, false},
	} {
		t.Run(tc.naam, func(t *testing.T) {
			r := newRecorder(t)
			r.on("GET /cluster/firewall/options", tc.antwoord)
			n, err := r.client(t).Afscherming(context.Background())
			if err != nil {
				t.Fatalf("Afscherming: %v", err)
			}
			if (n != "") != tc.melding {
				t.Errorf("notitie = %q, melding verwacht: %v", n, tc.melding)
			}
		})
	}
}
