package main

import (
	"context"
	"log/slog"
	"runtime/debug"
	"time"
)

// Een paniek in een goroutine zonder recover beëindigt het hele proces: de
// agent stopt dan ook met hartslagen en commando's, en de node lijkt dood
// terwijl alleen één nevenlus struikelde. handleCommand vangt dat al af; de
// lussen hieronder deden dat niet.

// vangPaniek logt een paniek in plaats van het proces te laten vallen. Als
// defer gebruiken, met als laatste regel van de goroutine.
func vangPaniek(logger *slog.Logger, wat string) {
	if r := recover(); r != nil {
		logger.Error(wat+": paniek opgevangen", "panic", r, "stack", string(debug.Stack()))
	}
}

// pauzeNaPaniek is hoe lang blijfDraaien wacht voor het een lus opnieuw start,
// zodat een paniek die elke keer optreedt de log niet volspuit.
var pauzeNaPaniek = 30 * time.Second

// blijfDraaien draait lus, en start hem na een paniek opnieuw tot ctx klaar
// is. Keert lus gewoon terug, dan is blijfDraaien ook klaar.
func blijfDraaien(ctx context.Context, logger *slog.Logger, wat string, lus func()) {
	for {
		if !geenPaniek(logger, wat, lus) {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(pauzeNaPaniek):
			logger.Info(wat + ": opnieuw gestart na een paniek")
		}
	}
}

// geenPaniek draait lus en zegt of die in paniek raakte.
func geenPaniek(logger *slog.Logger, wat string, lus func()) (raakteInPaniek bool) {
	defer func() {
		if r := recover(); r != nil {
			logger.Error(wat+": paniek opgevangen", "panic", r, "stack", string(debug.Stack()))
			raakteInPaniek = true
		}
	}()
	lus()
	return false
}
