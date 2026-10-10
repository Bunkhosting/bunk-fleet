package main

import (
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

func TestFirstSightIsTheOnlyTimeYouExecute(t *testing.T) {
	m := newCommandMemos(8)

	if prior := m.accept("cmd-1"); prior != nil {
		t.Fatal("first sight returned a prior memo")
	}
	if prior := m.accept("cmd-1"); prior == nil {
		t.Fatal("second sight looked like a first")
	}
}

func TestARedeliveredFinishedCommandAnswersWithItsResult(t *testing.T) {
	// The control plane only asks again when it never got an answer. Staying
	// silent leaves the command delivered forever — a VPS stuck mid-restore.
	m := newCommandMemos(8)
	m.accept("cmd-1")
	m.record("cmd-1", transport.CommandResult{Status: "done", VMID: "106"})

	prior := m.accept("cmd-1")
	if prior == nil || !prior.done {
		t.Fatalf("prior = %+v, want a finished memo", prior)
	}
	if prior.result.Status != "done" || prior.result.VMID != "106" {
		t.Errorf("result = %+v, want the one that was recorded", prior.result)
	}
}

func TestARedeliveredRunningCommandSaysNothingYet(t *testing.T) {
	// Re-reporting a result we do not have would be a lie; re-executing would
	// start a second vzdump of the same guest.
	m := newCommandMemos(8)
	m.accept("cmd-1")

	prior := m.accept("cmd-1")
	if prior == nil {
		t.Fatal("a running command looked unseen")
	}
	if prior.done {
		t.Error("a running command reported itself finished")
	}
}

func TestRecordingAfterEvictionIsNotACrash(t *testing.T) {
	// A long command can outlive its own memo on a busy agent.
	m := newCommandMemos(1)
	m.accept("cmd-1")
	m.accept("cmd-2") // evicts cmd-1

	m.record("cmd-1", transport.CommandResult{Status: "done"})

	if prior := m.accept("cmd-1"); prior != nil {
		t.Error("an evicted command was remembered after all")
	}
}

func TestTheMemoStoreIsBounded(t *testing.T) {
	m := newCommandMemos(4)
	for _, id := range []string{"a", "b", "c", "d", "e", "f"} {
		m.accept(id)
	}

	if len(m.byID) != 4 {
		t.Errorf("held %d memos, want 4", len(m.byID))
	}
	if prior := m.accept("a"); prior != nil {
		t.Error("the oldest memo survived eviction")
	}
	if prior := m.accept("f"); prior == nil {
		t.Error("the newest memo was lost")
	}
}

func TestAnEmptyIdIsNeverRemembered(t *testing.T) {
	m := newCommandMemos(4)
	if prior := m.accept(""); prior != nil {
		t.Error("an empty id returned a memo")
	}
	m.record("", transport.CommandResult{Status: "done"})
	if len(m.byID) != 0 {
		t.Errorf("held %d memos for an empty id", len(m.byID))
	}
}

func TestConcurrentUseIsSafe(t *testing.T) {
	// A backup finishing while the poll loop accepts the next command is the
	// ordinary case, not a rare one.
	m := newCommandMemos(64)
	var wg sync.WaitGroup

	for i := 0; i < 32; i++ {
		wg.Add(2)
		id := string(rune('a' + i%26))
		go func() { defer wg.Done(); m.accept(id) }()
		go func() { defer wg.Done(); m.record(id, transport.CommandResult{Status: "done"}) }()
	}
	wg.Wait()
}

// Een afgerond commando overleeft een herstart. Zonder dit voerde de agent een
// herleverde terugzetactie na een herstart gewoon nog een keer uit.
func TestEenAfgerondResultaatOverleeftEenHerstart(t *testing.T) {
	pad := filepath.Join(t.TempDir(), "memo.json")

	voor := laadCommandMemos(16, pad)
	voor.accept("restore-1")
	voor.record("restore-1", transport.CommandResult{Status: "done", VMID: "131"})
	voor.accept("loopt-nog")

	na := laadCommandMemos(16, pad)

	prior := na.accept("restore-1")
	if prior == nil || !prior.done || prior.result.VMID != "131" {
		t.Fatalf("na herstart: %+v; wilde het afgeronde resultaat terug", prior)
	}
	// Wat nog liep toen de agent stopte, moet na een herstart echt opnieuw.
	if na.accept("loopt-nog") != nil {
		t.Error("een commando dat nog liep, wordt na een herstart niet opnieuw uitgevoerd")
	}
}

func TestEenKapotMemobestandHoudtDeAgentNietTegen(t *testing.T) {
	pad := filepath.Join(t.TempDir(), "memo.json")
	if err := os.WriteFile(pad, []byte("{kapot"), 0o600); err != nil {
		t.Fatal(err)
	}
	m := laadCommandMemos(16, pad)
	if m.accept("nieuw") != nil {
		t.Error("een nieuw commando werd als bekend gezien")
	}
}
