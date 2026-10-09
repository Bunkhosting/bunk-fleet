package main

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"
)

// afschermendeStub is een stubProvider die ook iets zegt over afscherming, en
// telt hoe vaak hij gevraagd wordt.
type afschermendeStub struct {
	stubProvider
	notitie string
	err     error
	vragen  *int
}

func (s afschermendeStub) Afscherming(context.Context) (string, error) {
	*s.vragen++
	return s.notitie, s.err
}

func stilleLogger() *slog.Logger { return slog.New(slog.NewTextHandler(new(strings.Builder), nil)) }

func TestAfschermingWordtNietElkeHartslagGevraagd(t *testing.T) {
	vragen := 0
	prov := afschermendeStub{notitie: "firewall uit", vragen: &vragen}
	m := &afschermingsMelder{}

	for i := 0; i < 3; i++ {
		if got := m.notitie(context.Background(), stilleLogger(), prov); got != "firewall uit" {
			t.Fatalf("ronde %d: notitie %q", i, got)
		}
	}
	if vragen != 1 {
		t.Errorf("de hypervisor is %d keer gevraagd binnen de wachttijd, wilde 1", vragen)
	}

	// Na de wachttijd wordt opnieuw gevraagd: een operator die de firewall
	// aanzet, moet de melding zien verdwijnen zonder de agent te herstarten.
	m.laatst = time.Now().Add(-afschermingOpnieuwNa - time.Second)
	prov.notitie = ""
	if got := m.notitie(context.Background(), stilleLogger(), prov); got != "" {
		t.Errorf("na het aanzetten bleef de notitie staan: %q", got)
	}
}

func TestEenMislukteVraagHoudtHetVorigeAntwoord(t *testing.T) {
	// Een API die even hapert maakt een node niet ineens veilig.
	vragen := 0
	m := &afschermingsMelder{}
	m.notitie(context.Background(), stilleLogger(), afschermendeStub{notitie: "firewall uit", vragen: &vragen})

	m.laatst = time.Time{}
	got := m.notitie(context.Background(), stilleLogger(),
		afschermendeStub{err: errors.New("timeout"), vragen: &vragen})
	if got != "firewall uit" {
		t.Errorf("na een mislukte vraag: %q, wilde de vorige notitie", got)
	}
}

func TestEenProviderZonderAfschermingZegtNiets(t *testing.T) {
	if got := (&afschermingsMelder{}).notitie(context.Background(), stilleLogger(), stubProvider{}); got != "" {
		t.Errorf("notitie %q van een provider die het niet weet", got)
	}
}

func TestVoegSamen(t *testing.T) {
	for _, tc := range []struct{ a, b, want string }{
		{"", "", ""},
		{"net", "", "net"},
		{"", "fw", "fw"},
		{"net", "fw", "net | fw"},
	} {
		if got := voegSamen(tc.a, tc.b); got != tc.want {
			t.Errorf("voegSamen(%q, %q) = %q, wilde %q", tc.a, tc.b, got, tc.want)
		}
	}
}
