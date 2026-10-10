package esxi

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"testing"

	"github.com/vmware/govmomi/find"
	"github.com/vmware/govmomi/simulator"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

func testClient(t *testing.T) (*Client, func()) {
	t.Helper()
	model := simulator.VPX()
	if err := model.Create(); err != nil {
		t.Fatalf("simulator create: %v", err)
	}
	server := model.Service.NewServer()

	c, err := New(Config{
		URL:          server.URL.String(),
		User:         "user",
		Password:     "pass",
		Insecure:     true,
		Datastore:    "LocalDS_0",
		ResourcePool: "/DC0/host/DC0_H0/Resources",
		Template:     "DC0_H0_VM0",
	})
	if err != nil {
		server.Close()
		model.Remove()
		t.Fatalf("New: %v", err)
	}
	return c, func() { server.Close(); model.Remove() }
}

func TestNewValidation(t *testing.T) {
	if _, err := New(Config{}); err == nil {
		t.Error("expected error for empty config")
	}
	if _, err := New(Config{URL: "https://x/sdk", User: "u", Password: "p"}); err == nil {
		t.Error("expected error when template is missing")
	}
	if _, err := New(Config{URL: "https://x/sdk", User: "u", Password: "p", Template: "t"}); err != nil {
		t.Errorf("unexpected error for valid config: %v", err)
	}
}

func TestCapacity(t *testing.T) {
	c, done := testClient(t)
	defer done()

	cap, err := c.Capacity(context.Background())
	if err != nil {
		t.Fatalf("Capacity: %v", err)
	}
	if cap.TotalVCPU <= 0 || cap.TotalRAMMB <= 0 {
		t.Errorf("expected positive capacity, got %+v", cap)
	}
	if cap.AvailVCPU < 0 || cap.AvailRAMMB < 0 {
		t.Errorf("availability must not be negative: %+v", cap)
	}
}

func TestLifecycle(t *testing.T) {
	c, done := testClient(t)
	defer done()
	ctx := context.Background()

	st, err := c.CreateVM(ctx, provider.VMSpec{
		Name: "bunk-test", VCPU: 2, RAMMB: 2048, DiskGB: 20,
		SSHKeys:  []string{"ssh-rsa AAAATESTKEY bunk"},
		IPConfig: "ip=10.20.0.5/24,gw=10.20.0.1",
	})
	if err != nil {
		t.Fatalf("CreateVM: %v", err)
	}
	if st.ID == "" {
		t.Fatal("CreateVM returned empty ID")
	}

	fst, found, err := c.FindByName(ctx, "bunk-test")
	if err != nil || !found {
		t.Fatalf("FindByName: found=%v err=%v", found, err)
	}
	if fst.ID != st.ID {
		t.Errorf("FindByName id %q != create id %q", fst.ID, st.ID)
	}

	if err := c.PowerOff(ctx, st.ID); err != nil {
		t.Fatalf("PowerOff: %v", err)
	}
	if s, _ := c.StatusVM(ctx, st.ID); s.State != "stopped" {
		t.Errorf("after PowerOff expected stopped, got %q", s.State)
	}

	if err := c.PowerOn(ctx, st.ID); err != nil {
		t.Fatalf("PowerOn: %v", err)
	}
	if s, _ := c.StatusVM(ctx, st.ID); s.State != "running" {
		t.Errorf("after PowerOn expected running, got %q", s.State)
	}

	if err := c.Suspend(ctx, st.ID); err != nil {
		t.Fatalf("Suspend: %v", err)
	}
	if s, _ := c.StatusVM(ctx, st.ID); s.State != "paused" {
		t.Errorf("after Suspend expected paused, got %q", s.State)
	}
	if err := c.Resume(ctx, st.ID); err != nil {
		t.Fatalf("Resume: %v", err)
	}

	if err := c.DeleteVM(ctx, st.ID, ""); err != nil {
		t.Fatalf("DeleteVM: %v", err)
	}
	if _, found, _ := c.FindByName(ctx, "bunk-test"); found {
		t.Error("VM still present after DeleteVM")
	}

	// Deleting an already-gone VM is a no-op success.
	if err := c.DeleteVM(ctx, st.ID, ""); err != nil {
		t.Errorf("DeleteVM of missing VM should succeed, got %v", err)
	}
}

func TestNetworkConfig(t *testing.T) {
	if got := networkConfig("ip=dhcp"); got != "" {
		t.Errorf("dhcp should yield empty network config, got %q", got)
	}
	got := networkConfig("ip=10.0.0.5/24,gw=10.0.0.1")
	if got == "" {
		t.Fatal("expected network config for static ip")
	}
	if !contains(got, "10.0.0.5/24") || !contains(got, "10.0.0.1") {
		t.Errorf("network config missing ip/gw: %q", got)
	}
}

func TestCloudInitUserPassword(t *testing.T) {
	_, userdata := cloudInit(provider.VMSpec{
		Name:      "vm1",
		SSHKeys:   []string{"ssh-rsa AAAA key"},
		CloudInit: map[string]string{"user": "bunk", "password": "s3cret"},
	})
	if !contains(userdata, "chpasswd:") || !contains(userdata, "name: 'bunk'") ||
		!contains(userdata, "password: 's3cret'") || !contains(userdata, "ssh_pwauth: true") {
		t.Errorf("userdata missing password stanza: %q", userdata)
	}
}

// Een wachtwoord is willekeurige tekst en YAML leest willekeurige tekst als
// structuur. Zonder aanhalingstekens wordt `{a: b}` een map, `*x` een verwijzing
// en verdwijnt alles achter een `#`. Geen inbraak -- de waarde komt van ons eigen
// control plane -- maar wel een klant die niet in zijn verse VPS komt om een
// reden die aan de buitenkant niet te zien is.
func TestCloudInitQuotesAwkwardPasswords(t *testing.T) {
	gevallen := []struct {
		naam, wachtwoord, verwacht string
	}{
		{"map", "{a: b}", "password: '{a: b}'"},
		{"anchor", "*anchor", "password: '*anchor'"},
		{"hekje", "geheim # nietwaar", "password: 'geheim # nietwaar'"},
		{"boolean", "yes", "password: 'yes'"},
		{"aanhalingsteken", "het's", "password: 'het''s'"},
	}

	for _, g := range gevallen {
		t.Run(g.naam, func(t *testing.T) {
			_, userdata := cloudInit(provider.VMSpec{
				Name:      "vm1",
				CloudInit: map[string]string{"user": "bunk", "password": g.wachtwoord},
			})
			if !contains(userdata, g.verwacht) {
				t.Errorf("verwachtte %q in de userdata, kreeg:\n%s", g.verwacht, userdata)
			}
		})
	}
}

func TestCloudInitRejectsMultilineInjection(t *testing.T) {
	_, userdata := cloudInit(provider.VMSpec{
		Name:      "vm1",
		SSHKeys:   []string{"ssh-rsa AAAA\nruncmd:\n  - rm -rf /"},
		CloudInit: map[string]string{"user": "bunk", "password": "p\nruncmd: evil"},
	})
	if contains(userdata, "runcmd") {
		t.Errorf("multiline value must be dropped, not injected: %q", userdata)
	}
	// The password contained a newline, so the whole password stanza is dropped.
	if contains(userdata, "chpasswd:") {
		t.Errorf("invalid multiline password must not produce a chpasswd stanza: %q", userdata)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}

// isNotFound decides whether a delete reports success. Delete commands are
// re-delivered, so the second one finds nothing — and if that reads as a
// failure, the VPS never leaves :deleting.
//
// These cases pass against both the typed check and the message check that
// backs it up, which is the point: what is pinned here is the answer, not which
// of the two paths produced it. The typed check exists so the answer does not
// depend on govmomi's wording, and the last two cases are why the message check
// cannot stand alone — "connection refused" is not a missing guest.
func TestIsNotFoundSeesThroughWrapping(t *testing.T) {
	bare := &find.NotFoundError{}

	cases := map[string]struct {
		err  error
		want bool
	}{
		"nil":                    {nil, false},
		"bare not-found":         {bare, true},
		"wrapped once":           {fmt.Errorf("esxi: power state: %w", bare), true},
		"wrapped twice":          {fmt.Errorf("outer: %w", fmt.Errorf("inner: %w", bare)), true},
		"plain message":          {errors.New("vm not found on host"), true},
		"unrelated failure":      {errors.New("connection refused"), false},
		"wrapped unrelated":      {fmt.Errorf("esxi: destroy: %w", errors.New("permission denied")), false},
		"http 404 van een proxy": {errors.New("esxi: connect: 404 Not Found"), false},
		"transportfout":          {fmt.Errorf("esxi: power state: %w", &url.Error{Op: "Post", URL: "https://esx/sdk", Err: errors.New("host not found")}), false},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := isNotFound(tc.err); got != tc.want {
				t.Errorf("isNotFound(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
