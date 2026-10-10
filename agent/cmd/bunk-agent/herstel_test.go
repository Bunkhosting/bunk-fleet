package main

import (
	"context"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestBlijfDraaienStartEenLusNaEenPaniekOpnieuw(t *testing.T) {
	oud := pauzeNaPaniek
	pauzeNaPaniek = time.Millisecond
	defer func() { pauzeNaPaniek = oud }()

	var log strings.Builder
	logger := slog.New(slog.NewTextHandler(&log, nil))
	keer := 0
	blijfDraaien(context.Background(), logger, "proef", func() {
		keer++
		if keer < 3 {
			panic("stuk")
		}
	})

	if keer != 3 {
		t.Errorf("de lus draaide %d keer, wilde 3 (twee keer paniek, dan gewoon klaar)", keer)
	}
	if !strings.Contains(log.String(), "paniek opgevangen") {
		t.Error("de paniek staat niet in de log")
	}
}

func TestBlijfDraaienStoptAlsDeContextKlaarIs(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))
	keer := 0
	blijfDraaien(ctx, logger, "proef", func() {
		keer++
		panic("stuk")
	})
	if keer != 1 {
		t.Errorf("na een afgebroken context nog %d keer gedraaid", keer)
	}
}

func TestVangPaniekHoudtDeGoroutineBinnen(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(new(strings.Builder), nil))
	klaar := make(chan struct{})
	go func() {
		defer close(klaar)
		defer vangPaniek(logger, "proef")
		panic("stuk")
	}()
	<-klaar // zonder vangPaniek was het testproces hier al gestopt
}
