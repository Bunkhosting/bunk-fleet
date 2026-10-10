package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// Een opdracht zonder vm_id mag de hypervisor niet bereiken: ESXi zocht een VM
// met een lege referentie en kon een "niet gevonden" als "al weg" lezen. De
// stubProvider paniekt bij DeleteVM, dus een aanroep laat deze test vallen.
func TestEenVerwijderingZonderVmIdFaaltZonderDeHypervisorTeVragen(t *testing.T) {
	var uitslag transport.CommandResult
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/result") {
			if err := json.NewDecoder(r.Body).Decode(&uitslag); err != nil {
				t.Errorf("uitslag is geen json: %v", err)
			}
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	cp := transport.New(srv.URL, nil)
	cp.SetCredentials("node-1", "token-1")

	handleDelete(command{
		ctx:    context.Background(),
		logger: slog.New(slog.NewTextHandler(new(strings.Builder), nil)),
		prov:   stubProvider{capacity: provider.Capacity{}},
		cp:     cp,
		memos:  newCommandMemos(16),
		cmd:    transport.Command{ID: "cmd-1", Kind: "delete", Payload: json.RawMessage(`{"vm_id":""}`)},
	})

	if uitslag.Status != "failed" {
		t.Fatalf("status = %q, wil failed", uitslag.Status)
	}
	if !strings.Contains(uitslag.Error, "vm_id") {
		t.Errorf("de fout zegt niet wat er ontbrak: %q", uitslag.Error)
	}
}
