package main

import (
	"encoding/json"
	"log/slog"
	"os"
	"sync"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// commandMemos remembers what this agent did with each command it accepted.
//
// It exists because replay protection and result delivery pull in opposite
// directions. The control plane re-delivers a command whose result it never
// received — which is exactly what happens when the report POST fails, and the
// report POST fails whenever the control plane restarts at the wrong moment, so
// on every deploy. Dropping the redelivery as a duplicate, which is what an
// execute-once set alone does, leaves that command `:delivered` forever.
//
// For a provision that means a VPS stuck in `:provisioning`; for a restore, a
// customer's VPS stuck in `:restoring`, unable to be started, stopped or
// restored again. The command is wedged and nothing retries it.
//
// So the rule is: execute once, report as often as asked. A command that has
// finished re-reports its stored result. One still running says nothing — its
// result is coming.
type commandMemos struct {
	mu    sync.Mutex
	byID  map[string]*commandMemo
	order []string
	max   int

	// pad is waar afgeronde resultaten bewaard worden; leeg = alleen in het
	// geheugen. Zie bewaar.
	pad string
}

type commandMemo struct {
	done   bool
	result transport.CommandResult
}

func newCommandMemos(max int) *commandMemos {
	return &commandMemos{byID: make(map[string]*commandMemo, max), max: max}
}

// accept records that a command has been taken on. It returns the memo of a
// previous acceptance when there is one, and nil when this is the first sight —
// which is the only case the caller should execute.
func (m *commandMemos) accept(id string) *commandMemo {
	if id == "" {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	if existing, ok := m.byID[id]; ok {
		// Return a copy: the caller reads it outside the lock, and the command it
		// belongs to may still be finishing on another goroutine.
		snapshot := *existing
		return &snapshot
	}

	m.byID[id] = &commandMemo{}
	m.order = append(m.order, id)
	// Bounded: a long-lived agent must not grow a map for every command it has
	// ever seen. Evicting the oldest can at worst let a very old redelivery
	// execute twice, which the control plane's own idempotency already covers.
	if len(m.order) > m.max {
		delete(m.byID, m.order[0])
		m.order = m.order[1:]
	}
	return nil
}

// record stores the outcome so a later redelivery can be answered without doing
// the work again.
func (m *commandMemos) record(id string, res transport.CommandResult) {
	if id == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	memo, ok := m.byID[id]
	if !ok {
		// Evicted while the command ran, or never accepted. Nothing to attach to.
		return
	}
	memo.done = true
	memo.result = res
	m.bewaar()
}

// bewaarde is een afgerond commando zoals het op schijf staat.
type bewaarde struct {
	ID     string                  `json:"id"`
	Result transport.CommandResult `json:"result"`
}

// bewaar schrijft de afgeronde resultaten naar schijf. Aanroepen met m.mu vast.
//
// Waarom: het geheugen van de agent herhaalt een resultaat als het control
// plane er opnieuw om vraagt. Stond dat alleen in RAM, dan was het na een
// herstart weg, en voerde de agent een herleverd commando gewoon nog een keer
// uit. Voor een terugzetactie betekent dat: klaar, resultaat niet afgeleverd
// (het control plane herstartte net), agent herstart, terugzetten nog een keer
// -- en alles wat de klant in de tussentijd schreef is weg. Alleen afgeronde
// commando's: wat nog liep, moet na een herstart echt opnieuw.
func (m *commandMemos) bewaar() {
	if m.pad == "" {
		return
	}
	lijst := make([]bewaarde, 0, len(m.order))
	for _, id := range m.order {
		if memo := m.byID[id]; memo != nil && memo.done {
			lijst = append(lijst, bewaarde{ID: id, Result: memo.result})
		}
	}
	b, err := json.Marshal(lijst)
	if err != nil {
		slog.Warn("command memo: kon het geheugen niet omzetten naar json", "err", err)
		return
	}
	// Mislukt het schrijven, dan geldt het geheugen nog steeds tot de
	// herstart. Maar wel zichtbaar: een volle schijf betekent dat afgeronde
	// commando's een herstart niet meer overleven, en dat merkt anders niemand
	// tot een terugzetactie twee keer draait.
	if err := schrijfAtomisch(m.pad, b); err != nil {
		slog.Warn("command memo: kon het geheugen niet bewaren; het geldt tot de volgende herstart",
			"pad", m.pad, "err", err)
	}
}

// laadCommandMemos maakt het geheugen aan en vult het met wat er bij een
// vorige run is bewaard. Een ontbrekend of onleesbaar bestand is een leeg
// geheugen, geen fout: de agent moet altijd kunnen starten.
func laadCommandMemos(max int, pad string) *commandMemos {
	m := newCommandMemos(max)
	m.pad = pad
	if pad == "" {
		return m
	}
	b, err := os.ReadFile(pad)
	if err != nil {
		if !os.IsNotExist(err) {
			slog.Warn("command memo: bewaard geheugen onleesbaar; begonnen met een leeg", "pad", pad, "err", err)
		}
		return m
	}
	var lijst []bewaarde
	if err := json.Unmarshal(b, &lijst); err != nil {
		slog.Warn("command memo: bewaard geheugen beschadigd; begonnen met een leeg", "pad", pad, "err", err)
		return m
	}
	if len(lijst) > max {
		lijst = lijst[len(lijst)-max:]
	}
	for _, e := range lijst {
		if e.ID == "" {
			continue
		}
		m.byID[e.ID] = &commandMemo{done: true, result: e.Result}
		m.order = append(m.order, e.ID)
	}
	return m
}
