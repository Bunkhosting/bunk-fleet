package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// stubProvider answers Capacity and panics on everything else: a heartbeat has
// no business calling the rest, and a panic says so louder than a nil return.
type stubProvider struct {
	capacity provider.Capacity
	err      error
}

func (s stubProvider) Capacity(context.Context) (provider.Capacity, error) {
	return s.capacity, s.err
}

func (stubProvider) Name() string { return "stub" }

func (stubProvider) CreateVM(context.Context, provider.VMSpec) (provider.VMStatus, error) {
	panic("not used by a heartbeat")
}
func (stubProvider) DeleteVM(context.Context, string, string) error {
	panic("not used by a heartbeat")
}
func (stubProvider) StatusVM(context.Context, string) (provider.VMStatus, error) {
	panic("not used by a heartbeat")
}
func (stubProvider) FindByName(context.Context, string) (provider.VMStatus, bool, error) {
	panic("not used by a heartbeat")
}
func (stubProvider) Reboot(context.Context, string) error { panic("not used by a heartbeat") }
func (stubProvider) ListGuestIDs(context.Context) ([]string, error) {
	panic("not used by a heartbeat")
}
func (stubProvider) PowerOn(context.Context, string) error  { panic("not used by a heartbeat") }
func (stubProvider) PowerOff(context.Context, string) error { panic("not used by a heartbeat") }
func (stubProvider) Suspend(context.Context, string) error  { panic("not used by a heartbeat") }
func (stubProvider) Resume(context.Context, string) error   { panic("not used by a heartbeat") }
func (stubProvider) BackupVM(context.Context, string) (provider.Backup, error) {
	panic("not used by a heartbeat")
}
func (stubProvider) DeleteBackup(context.Context, string) error {
	panic("not used by a heartbeat")
}
func (stubProvider) RestoreVM(context.Context, string, string) error {
	panic("not used by a heartbeat")
}

// collect runs one heartbeat against a throwaway control plane and returns what
// arrived, or nil when nothing was sent at all.
func collect(t *testing.T, prov provider.Provider) *transport.Heartbeat {
	t.Helper()

	var got *transport.Heartbeat
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/heartbeat") {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		var hb transport.Heartbeat
		if err := json.NewDecoder(r.Body).Decode(&hb); err != nil {
			t.Errorf("heartbeat is geen geldige json: %v", err)
		}
		got = &hb
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	cp := transport.New(srv.URL, nil)
	cp.SetCredentials("node-1", "token-1")

	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))
	sendHeartbeat(context.Background(), logger, prov, cp, &offerHolder{v: config.OfferConfig{}}, nil, nil)

	return got
}

func TestHeartbeatCarriesCapacityWhenTheHypervisorAnswers(t *testing.T) {
	hb := collect(t, stubProvider{capacity: provider.Capacity{
		TotalVCPU: 8, AvailVCPU: 6,
		TotalRAMMB: 16384, AvailRAMMB: 8192,
		TotalDiskGB: 500, AvailDiskGB: 300,
	}})

	if hb == nil {
		t.Fatal("geen heartbeat verstuurd")
	}
	if hb.AvailRAMMB != 8192 || hb.TotalVCPU != 8 {
		t.Errorf("capaciteit kwam niet mee: %+v", hb)
	}
	if hb.CapacityError != "" {
		t.Errorf("onverwachte foutmelding op een gezonde heartbeat: %q", hb.CapacityError)
	}
}

func TestHeartbeatIsStillSentWhenTheHypervisorCannotBeReached(t *testing.T) {
	// Dit is de fout die deze test bewaakt. Eerder stuurde de agent in dit geval
	// helemaal niets, waarna het control plane de node na twee minuten offline
	// zette -- niet te onderscheiden van een machine die uit staat, terwijl de
	// agent draait en alleen zijn hypervisor niet kan bereiken.
	hb := collect(t, stubProvider{err: errors.New("proxmox: dial tcp 10.0.0.9:8006: connect: no route to host")})

	if hb == nil {
		t.Fatal("geen heartbeat verstuurd terwijl de agent leeft: de node lijkt dan dood")
	}
	if !strings.Contains(hb.CapacityError, "no route to host") {
		t.Errorf("de reden kwam niet mee: %q", hb.CapacityError)
	}
	if hb.TotalVCPU != 0 || hb.AvailRAMMB != 0 {
		t.Errorf("er is niets gemeten, dus er hoort geen getal in te staan: %+v", hb)
	}
}

// instelbareProvider legt vast wat er via ApplySettings binnenkomt.
type instelbareProvider struct {
	stubProvider
	laatste provider.Settings
}

func (p *instelbareProvider) ApplySettings(s provider.Settings) { p.laatste = s }

func TestSettingsUitHetDashboardWordenToegepast(t *testing.T) {
	prov := &instelbareProvider{}
	offer := &offerHolder{v: config.OfferConfig{VCPU: 1, RAMMB: 1024, DiskGB: 10}}
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	applySettings(logger, prov, offer, transport.NodeSettings{
		OfferVCPU: 4, OfferRAMMB: 8192, OfferDiskGB: 200,
		VMIDMin: 2000, VMIDMax: 2999, VCPUOversubscribe: 4,
	})

	if got := offer.get(); got.VCPU != 4 || got.RAMMB != 8192 || got.DiskGB != 200 {
		t.Errorf("aanbod niet overgenomen: %+v", got)
	}
	if prov.laatste.VMIDMin != 2000 || prov.laatste.VCPUOversubscribe != 4 {
		t.Errorf("provider-instellingen niet doorgegeven: %+v", prov.laatste)
	}
}

func TestNietIngesteldLaatDeLokaleWaardeStaan(t *testing.T) {
	// Dit is het verschil dat telt: niets ingesteld hebben is iets anders dan op
	// nul zetten, en alleen dat laatste hoort het gedrag te veranderen. Zou een
	// nul het aanbod overschrijven, dan biedt een node die nog nooit is
	// aangeraakt ineens niets meer aan.
	prov := &instelbareProvider{}
	lokaal := config.OfferConfig{VCPU: 2, RAMMB: 4096, DiskGB: 50}
	offer := &offerHolder{v: lokaal}
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	applySettings(logger, prov, offer, transport.NodeSettings{})

	if got := offer.get(); got != lokaal {
		t.Errorf("lokale configuratie overschreven door lege instellingen: %+v", got)
	}
}

func TestEenProviderZonderInstellingenGeeftGeenPaniek(t *testing.T) {
	// De Configurable-interface is optioneel; een provider die niets in te
	// stellen heeft implementeert hem niet en moet gewoon worden overgeslagen.
	offer := &offerHolder{v: config.OfferConfig{}}
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))

	applySettings(logger, stubProvider{}, offer, transport.NodeSettings{VMIDMin: 2000, VMIDMax: 2999})
}

func TestEenVeranderdeInstellingWordtGelogd(t *testing.T) {
	// Zonder logregel is niet vast te stellen of een node zijn instellingen heeft
	// opgepakt: een VMID-bereik landde stil, en alleen een gewijzigd aanbod gaf
	// een spoor.
	vorigeProviderSettings = provider.Settings{}
	var uit strings.Builder
	logger := slog.New(slog.NewTextHandler(&uit, nil))
	prov := &instelbareProvider{}
	offer := &offerHolder{v: config.OfferConfig{}}

	applySettings(logger, prov, offer, transport.NodeSettings{VMIDMin: 2000, VMIDMax: 2999})

	if !strings.Contains(uit.String(), "2000") {
		t.Errorf("het nieuwe bereik staat niet in de log: %q", uit.String())
	}

	// Een tweede keer dezelfde instellingen hoort stil te blijven, anders staat
	// de log elke dertig seconden vol met hetzelfde.
	uit.Reset()
	applySettings(logger, prov, offer, transport.NodeSettings{VMIDMin: 2000, VMIDMax: 2999})

	if uit.Len() != 0 {
		t.Errorf("ongewijzigde instellingen werden opnieuw gelogd: %q", uit.String())
	}
}

// Een reden die niet in de kolom van het control plane past laat de hele
// heartbeat afketsen -- en dan staat de node dood in het paneel om een
// foutmelding die te lang was. Afkappen moet dus, maar op een tekengrens: een
// half afgesneden rune is geen geldige UTF-8 meer en wordt net zo goed geweigerd.
func TestCapaciteitsredenAfkappen(t *testing.T) {
	kort := capacityReason(errors.New("proxmox: node onbereikbaar"))
	if kort != "proxmox: node onbereikbaar" {
		t.Errorf("korte reden veranderd: %q", kort)
	}

	// Een lege melding zou in het paneel een lege regel opleveren waar de reden
	// hoort te staan.
	if leeg := capacityReason(errors.New("   ")); leeg == "" {
		t.Error("een lege fout hoort nog steeds iets te zeggen")
	}

	if ascii := capacityReason(errors.New(strings.Repeat("x", 500))); len(ascii) > 255 {
		t.Errorf("reden niet afgekapt: %d bytes", len(ascii))
	}

	lang := capacityReason(errors.New(strings.Repeat("é", 400)))
	if len(lang) > 255 {
		t.Errorf("afgekapte reden is %d bytes; past niet in de kolom", len(lang))
	}
	if !utf8.ValidString(lang) {
		t.Error("afgekapte reden is geen geldige UTF-8; Postgres weigert hem")
	}
	if !strings.HasSuffix(lang, "…") {
		t.Errorf("afgekapte reden eindigt op %q; verwacht een beletselteken", lang[len(lang)-4:])
	}
}
