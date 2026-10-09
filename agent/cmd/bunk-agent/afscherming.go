package main

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

// Hoe vaak de agent de hypervisor vraagt of klanten van elkaar zijn afgeschermd.
// Elke hartslag zou elke dertig seconden een API-aanroep kosten voor iets wat
// alleen verandert als een mens in de Proxmox-interface een vinkje zet.
const afschermingOpnieuwNa = 5 * time.Minute

// afschermingsMelder onthoudt het laatste antwoord op "zijn klanten op deze node
// van elkaar afgeschermd", zodat de hartslag het kan meesturen zonder elke keer
// de hypervisor te bevragen.
type afschermingsMelder struct {
	mu      sync.Mutex
	laatst  time.Time
	melding string
}

// notitie geeft de melding voor het paneel, of "" als er niets te melden is of
// de provider het niet weet. Een mislukte vraag houdt het vorige antwoord: een
// API die even hapert maakt een node niet ineens veilig of onveilig.
func (m *afschermingsMelder) notitie(ctx context.Context, logger *slog.Logger, prov provider.Provider) string {
	if m == nil {
		return ""
	}
	a, ok := prov.(provider.Afscherming)
	if !ok {
		return ""
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.laatst.IsZero() && time.Since(m.laatst) < afschermingOpnieuwNa {
		return m.melding
	}
	n, err := a.Afscherming(ctx)
	if err != nil {
		logger.Warn("afscherming: kon de firewall-instelling niet lezen", "err", err)
		return m.melding
	}
	m.melding = n
	m.laatst = time.Now()
	return n
}

// voegSamen zet twee notities achter elkaar. De netwerknotitie staat voorop:
// die zegt dat de terminal niet werkt, en dat merkt een klant als eerste.
func voegSamen(a, b string) string {
	switch {
	case a == "":
		return b
	case b == "":
		return a
	default:
		return a + " | " + b
	}
}
