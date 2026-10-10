package main

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// persistedState is the on-disk state the agent reuses across restarts: the
// enrollment credentials plus the customer network it was assigned, so a reboot
// keeps the same node identity and reconfigures the same bridge without
// re-enrolling.
type persistedState struct {
	NodeID        string `json:"node_id"`
	AgentToken    string `json:"agent_token"`
	VpsGateway    string `json:"vps_gateway,omitempty"`
	VpsCidrPrefix int    `json:"vps_cidr_prefix,omitempty"`
}

// loadState reads persisted state; ok is false when none (or incomplete) exist.
func loadState(path string) (persistedState, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return persistedState{}, false
	}
	var st persistedState
	if err := json.Unmarshal(b, &st); err != nil || st.NodeID == "" || st.AgentToken == "" {
		return persistedState{}, false
	}
	return st, true
}

// saveState writes the state atomically with owner-only perms.
//
// Met fsync van het bestand vóór de rename en van de map erna. Zonder die twee
// kan een stroomstoring direct na het schrijven een leeg of half state.json
// achterlaten: de rename staat dan op schijf maar de inhoud niet. Dit bestand
// is de identiteit van de node; kwijt betekent opnieuw inschrijven met een
// token dat al gebruikt is.
func saveState(path string, st persistedState) error {
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	return schrijfAtomisch(path, b)
}

// schrijfAtomisch zet b in path zodat er na een stroomstoring ofwel de oude
// ofwel de nieuwe inhoud staat, nooit een half bestand. Alleen de eigenaar mag
// lezen.
func schrijfAtomisch(path string, b []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}
