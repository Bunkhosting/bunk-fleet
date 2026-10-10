package main

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// Twee klanten horen niet op elkaar te wachten. Dit is de hele reden dat
// werkers bestaat: een provision van tien minuten mag de stop van iemand anders
// niet ophouden.
func TestWerkersDraaienVerschillendeVPSenNaastElkaar(t *testing.T) {
	begonnen := make(chan string, 2)
	losgelaten := make(chan struct{})

	w := nieuweWerkers(4, func(cmd transport.Command) {
		begonnen <- cmd.VPSID
		<-losgelaten
	})

	w.stuur(transport.Command{ID: "1", VPSID: "traag", Kind: transport.CmdProvision})
	w.stuur(transport.Command{ID: "2", VPSID: "snel", Kind: transport.CmdStop})

	gezien := map[string]bool{}
	for i := 0; i < 2; i++ {
		select {
		case id := <-begonnen:
			gezien[id] = true
		case <-time.After(2 * time.Second):
			t.Fatalf("maar %d van de 2 commando's begonnen; de tweede wacht op de eerste", i)
		}
	}
	if !gezien["traag"] || !gezien["snel"] {
		t.Fatalf("niet allebei begonnen: %v", gezien)
	}

	close(losgelaten)
	w.wacht()
}

// En het tegenovergestelde: voor één VPS moet de volgorde blijven staan. Een
// klant die stop en dan start indrukt krijgt ze in één poll binnen; draaien ze
// om, dan staat zijn machine daarna uit.
func TestWerkersHoudenVolgordePerVPS(t *testing.T) {
	var mu sync.Mutex
	var volgorde []string

	w := nieuweWerkers(4, func(cmd transport.Command) {
		mu.Lock()
		volgorde = append(volgorde, cmd.ID)
		mu.Unlock()
		// Even blijven hangen, zodat een implementatie die ze naast elkaar zet
		// hier daadwerkelijk door elkaar gaat lopen in plaats van per toeval
		// goed te eindigen.
		time.Sleep(time.Millisecond)
	})

	verwacht := make([]string, 0, 20)
	for i := 0; i < 20; i++ {
		id := fmt.Sprintf("c%02d", i)
		verwacht = append(verwacht, id)
		w.stuur(transport.Command{ID: id, VPSID: "dezelfde", Kind: transport.CmdStop})
	}
	w.wacht()

	mu.Lock()
	defer mu.Unlock()
	if len(volgorde) != len(verwacht) {
		t.Fatalf("%d commando's uitgevoerd, %d verwacht", len(volgorde), len(verwacht))
	}
	for i := range verwacht {
		if volgorde[i] != verwacht[i] {
			t.Fatalf("op plek %d stond %q, verwacht %q (volgorde: %v)", i, volgorde[i], verwacht[i], volgorde)
		}
	}
}

// Commando's over de node zelf hebben geen VPS. Die horen ook na elkaar te
// lopen: twee keer tegelijk de inventaris opvragen voegt niets toe.
func TestWerkersZonderVPSIDInEenBaan(t *testing.T) {
	var tegelijk, piek int32

	w := nieuweWerkers(4, func(transport.Command) {
		n := atomic.AddInt32(&tegelijk, 1)
		for {
			oud := atomic.LoadInt32(&piek)
			if n <= oud || atomic.CompareAndSwapInt32(&piek, oud, n) {
				break
			}
		}
		time.Sleep(time.Millisecond)
		atomic.AddInt32(&tegelijk, -1)
	})

	for i := 0; i < 5; i++ {
		w.stuur(transport.Command{ID: fmt.Sprintf("i%d", i), Kind: transport.CmdInventory})
	}
	w.wacht()

	if piek != 1 {
		t.Fatalf("%d node-commando's liepen tegelijk; dat hoort er één te zijn", piek)
	}
}

// Meer VPS'en dan plekken mag niets laten liggen: het wordt trager, niet stuk.
func TestWerkersVoerenAllesUitOokBovenDeGrens(t *testing.T) {
	var uitgevoerd int32

	w := nieuweWerkers(2, func(transport.Command) {
		atomic.AddInt32(&uitgevoerd, 1)
	})

	for i := 0; i < 50; i++ {
		w.stuur(transport.Command{ID: fmt.Sprintf("c%d", i), VPSID: fmt.Sprintf("vps%d", i), Kind: transport.CmdStop})
	}
	w.wacht()

	if uitgevoerd != 50 {
		t.Fatalf("%d van de 50 commando's uitgevoerd", uitgevoerd)
	}
}

// Een baan die leegloopt hoort te verdwijnen, anders houdt de agent een
// goroutine per VPS die hij ooit heeft gezien.
func TestWerkersRuimenLegeBanenOp(t *testing.T) {
	w := nieuweWerkers(4, func(transport.Command) {})

	w.stuur(transport.Command{ID: "1", VPSID: "weg", Kind: transport.CmdStop})
	w.wacht()

	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.rijen) != 0 {
		t.Fatalf("er staan nog %d banen open", len(w.rijen))
	}
}

// De grens geldt voor het uitvoeren: nooit meer dan max tegelijk, ook met meer
// VPS'en dan plekken.
func TestWerkersOverschrijdenDeGrensNooit(t *testing.T) {
	var tegelijk, piek int32
	w := nieuweWerkers(2, func(transport.Command) {
		n := atomic.AddInt32(&tegelijk, 1)
		for {
			oud := atomic.LoadInt32(&piek)
			if n <= oud || atomic.CompareAndSwapInt32(&piek, oud, n) {
				break
			}
		}
		time.Sleep(2 * time.Millisecond)
		atomic.AddInt32(&tegelijk, -1)
	})
	for i := 0; i < 20; i++ {
		w.stuur(transport.Command{ID: fmt.Sprintf("c%d", i), VPSID: fmt.Sprintf("vps%d", i), Kind: transport.CmdStop})
	}
	w.wacht()
	if piek > 2 {
		t.Fatalf("%d commando's liepen tegelijk bij een grens van 2", piek)
	}
	if piek < 2 {
		t.Fatalf("piek %d: de proef liet niets naast elkaar lopen, dus bewijst hij niets", piek)
	}
}

// Bij een volle node mag de aanleveraar niet wachten. Die leest ook de
// console_connects; voerde hij zelf een uitrol uit, dan bleef de terminal van
// een klant minutenlang hangen.
func TestEenVolleNodeHoudtDeAanleveraarNietVast(t *testing.T) {
	los := make(chan struct{})
	w := nieuweWerkers(1, func(transport.Command) { <-los })

	klaar := make(chan struct{})
	go func() {
		w.stuur(transport.Command{ID: "a", VPSID: "vps-a", Kind: transport.CmdProvision})
		w.stuur(transport.Command{ID: "b", VPSID: "vps-b", Kind: transport.CmdProvision})
		w.stuur(transport.Command{ID: "c", VPSID: "vps-c", Kind: transport.CmdStop})
		close(klaar)
	}()

	select {
	case <-klaar:
	case <-time.After(2 * time.Second):
		t.Fatal("stuur bleef hangen terwijl de enige plek bezet was")
	}
	close(los)
	w.wacht()
}
