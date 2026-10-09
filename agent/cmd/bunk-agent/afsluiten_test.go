package main

import (
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestAfsluitenWachtOpWerkDatOpTijdKlaarIs(t *testing.T) {
	klaar := make(chan struct{})
	afgebroken := false

	go func() {
		time.Sleep(20 * time.Millisecond)
		close(klaar)
	}()
	wachtOpLopendWerk(slog.New(slog.NewTextHandler(new(strings.Builder), nil)), klaar,
		func() { afgebroken = true }, time.Second)

	if afgebroken {
		t.Error("werk dat binnen de wachttijd klaar was, is toch afgebroken")
	}
}

func TestAfsluitenBreektAfNaDeWachttijd(t *testing.T) {
	// Een clone die blijft hangen mag een herstart niet eindeloos ophouden:
	// daarna komt systemd met SIGKILL, en dan meldt niemand meer iets.
	klaar := make(chan struct{})
	afgebroken := false

	begin := time.Now()
	wachtOpLopendWerk(slog.New(slog.NewTextHandler(new(strings.Builder), nil)), klaar,
		func() { afgebroken = true; close(klaar) }, 30*time.Millisecond)

	if !afgebroken {
		t.Fatal("hangend werk is niet afgebroken")
	}
	if time.Since(begin) > 2*time.Second {
		t.Errorf("afsluiten duurde %s", time.Since(begin))
	}
}

func TestAfsluitenZonderConsumentWachtNiet(t *testing.T) {
	// Een agent die nog niet is ingeschreven heeft geen consument.
	wachtOpLopendWerk(slog.New(slog.NewTextHandler(new(strings.Builder), nil)), nil,
		func() { t.Error("afgebroken zonder consument") }, time.Hour)
}

func TestDeWachttijdBlijftOnderDeStopTijdVanSystemd(t *testing.T) {
	// systemd stuurt na 90 seconden SIGKILL. Daarna is er geen resultaat meer
	// te melden, en de afbreektijd van tien seconden moet er nog bij passen.
	if afsluitWachttijd+10*time.Second >= 90*time.Second {
		t.Errorf("wachttijd %s plus 10s komt niet onder de 90s van systemd", afsluitWachttijd)
	}
}
