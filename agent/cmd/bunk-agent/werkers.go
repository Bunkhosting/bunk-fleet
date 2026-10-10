package main

import (
	"sync"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// werkers verdeelt binnenkomende commando's over banen: één baan per VPS.
//
// Waarom dit er is: de consumer voerde elk commando uit op de plek waar hij het
// ontving, dus strikt na elkaar. Een provision duurt minuten (klonen, starten,
// cloud-init) en een stop duurt een seconde -- maar de klant die op "stop" drukt
// wacht net zo lang als de uitrol van iemand anders duurt. Dat is een node die
// traag lijkt terwijl hij niets doet.
//
// Waarom een baan per VPS en niet gewoon een poule van goroutines: twee
// commando's voor dezelfde machine mogen niet door elkaar lopen en al helemaal
// niet omdraaien. Een klant die snel achter elkaar stop en start indrukt krijgt
// ze in één poll binnen; komt de start eerst aan de beurt, dan staat zijn VPS
// daarna uit terwijl hij hem net had aangezet. Binnen een baan blijft de
// volgorde die de control plane bedoelde.
//
// Een commando zonder VPS (inventory, update) krijgt één gedeelde baan. Die
// gaan over de node als geheel; naast elkaar draaien voegt daar niets toe.
type werkers struct {
	mu    sync.Mutex
	rijen map[string]chan transport.Command

	// Hoeveel commando's er tegelijk mogen lopen. Niet oneindig: een provision
	// is op Proxmox vooral schijfwerk, en tien klonen tegelijk maakt een node
	// niet sneller maar alleen trager voor iedereen.
	//
	// De grens zit op het uitvoeren, niet op het aantal banen. Zat hij op de
	// banen, dan werd een commando bij een volle node uitgevoerd op de plek waar
	// het binnenkwam: in de consumer. Die las dan minutenlang niets -- ook geen
	// console_connect, dus de terminal van een klant bleef hangen omdat een
	// ander een VPS bestelde. Nu krijgt elk commando meteen een baan en wacht
	// het daar op een vrije plek; de consumer wacht nooit.
	max     int
	plekken chan struct{}

	uitvoeren func(transport.Command)
	klaar     sync.WaitGroup
}

// Hoeveel commando's er in een baan mogen wachten voordat de aanleveraar moet
// wachten. Ruim genoeg voor een normale batch van een poll; loopt hij vol, dan
// blokkeert de aanleveraar, en ook dat is het oude gedrag.
const rijDiepte = 32

func nieuweWerkers(max int, uitvoeren func(transport.Command)) *werkers {
	if max < 1 {
		max = 1
	}
	return &werkers{
		rijen:     make(map[string]chan transport.Command, max),
		max:       max,
		plekken:   make(chan struct{}, max),
		uitvoeren: uitvoeren,
	}
}

// baan is de sleutel waarop commando's van elkaar gescheiden worden.
func baan(cmd transport.Command) string {
	if cmd.VPSID != "" {
		return cmd.VPSID
	}
	// Een control plane die nog geen vps_id meestuurt, of een commando over de
	// node zelf. Beide horen in dezelfde baan: zonder te weten waar een
	// commando over gaat, is na elkaar de enige veilige volgorde.
	return ""
}

// stuur zet een commando in de baan van zijn VPS en zorgt dat die baan loopt.
func (w *werkers) stuur(cmd transport.Command) {
	sleutel := baan(cmd)

	w.mu.Lock()
	rij, bestaat := w.rijen[sleutel]
	if !bestaat {
		rij = make(chan transport.Command, rijDiepte)
		w.rijen[sleutel] = rij
		w.klaar.Add(1)
		go w.draai(sleutel, rij)
	}
	// Het slot blijft vastzitten tijdens het versturen. Dat is expres: zo kan de
	// baan niet tussen het opzoeken en het versturen door besluiten dat hij leeg
	// is en verdwijnen. Vastlopen kan het niet -- de baan heeft het slot niet
	// nodig om te blijven lezen, alleen om te stoppen, en stoppen doet hij
	// alleen als zijn rij leeg is.
	rij <- cmd
	w.mu.Unlock()
}

func (w *werkers) draai(sleutel string, rij chan transport.Command) {
	defer w.klaar.Done()

	for {
		select {
		case cmd := <-rij:
			w.plekken <- struct{}{}
			w.uitvoeren(cmd)
			<-w.plekken
		default:
			// Leeg. Onder het slot nog één keer kijken, want tussen het lezen
			// hierboven en het slot hieronder kan er iets bij zijn gekomen.
			w.mu.Lock()
			if len(rij) == 0 {
				delete(w.rijen, sleutel)
				w.mu.Unlock()
				return
			}
			w.mu.Unlock()
		}
	}
}

// wacht keert terug als alle banen leeg zijn en gestopt. Alleen voor tests en
// voor een nette afsluiting.
func (w *werkers) wacht() {
	w.klaar.Wait()
}
