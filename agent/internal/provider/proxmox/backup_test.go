package proxmox

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestStorageOfPullsTheStorageNameOutOfAVolid(t *testing.T) {
	got, err := storageOf("local:backup/vzdump-qemu-106-2026_09_11-20_15_00.vma.zst")
	if err != nil || got != "local" {
		t.Fatalf("storageOf = %q, %v; want local", got, err)
	}
}

func TestStorageOfRejectsWhatWouldBreakOutOfAnApiPath(t *testing.T) {
	// The result is interpolated into /nodes/x/storage/<here>/content, so a
	// malformed volid is a request somewhere else entirely.
	for _, bad := range []string{
		"",
		"local",
		"local:",
		":backup/x",
		"../../etc:backup/x",
		"has space:backup/x",
	} {
		if _, err := storageOf(bad); err == nil {
			t.Errorf("storageOf accepted %q", bad)
		}
	}
}

func TestBackupStorageFallsBackToLocal(t *testing.T) {
	c := &Client{cfg: Config{}}
	if got := c.backupStorage(); got != "local" {
		t.Errorf("backupStorage = %q, want local", got)
	}

	c = &Client{cfg: Config{BackupStorage: "  "}}
	if got := c.backupStorage(); got != "local" {
		t.Errorf("blank BackupStorage = %q, want local", got)
	}

	c = &Client{cfg: Config{BackupStorage: "nvme-backups"}}
	if got := c.backupStorage(); got != "nvme-backups" {
		t.Errorf("backupStorage = %q, want nvme-backups", got)
	}
}

func TestIsNotFoundOnlyMatchesA404(t *testing.T) {
	// Treating any error as "already gone" would report a failed deletion as a
	// success and leave the archive filling the node's disk.
	if !isNotFound(errString("proxmox: delete backup: status 404: not found")) {
		t.Error("a 404 was not recognised")
	}
	for _, other := range []string{
		"proxmox: delete backup: status 500: internal error",
		"proxmox: delete backup: connection refused",
		"",
	} {
		if isNotFound(errString(other)) {
			t.Errorf("isNotFound matched %q", other)
		}
	}
	if isNotFound(nil) {
		t.Error("isNotFound matched nil")
	}
}

type errString string

func (e errString) Error() string { return string(e) }

// Een afgebroken wachtbeurt is niet hetzelfde als een mislukte back-up.
//
// Wordt de agent herstart terwijl er een vzdump loopt, dan valt het commando
// weg maar werkt Proxmox door. Meldt de agent dan alleen "mislukt", dan leest
// de klant dat zijn back-up niet is gelukt terwijl hij er wel staat -- en het
// control plane kent alleen archieven waarvan het de volid heeft, dus dat
// bestand heeft vanaf dat moment geen handvat meer. Zo bleef er op productie
// twee gigabyte staan van machines die allang weg waren.
func TestBackupVMNeemtEenArchiefDatErTochKwam(t *testing.T) {
	r := newRecorder(t)
	r.on("POST /nodes/pve/vzdump", okTask)
	// Het wachten loopt nooit af; de context eronder wordt afgebroken.
	r.on("GET /nodes/pve/tasks/UPID:pve:0000:OK::task/status", `{"data":{"status":"running"}}`)
	r.on("GET /nodes/pve/storage/local/content", fmt.Sprintf(
		`{"data":[{"volid":"local:backup/vzdump-qemu-7-nu.vma.zst","size":123,"ctime":%d}]}`,
		time.Now().Unix()+5))

	ctx, annuleer := context.WithCancel(context.Background())
	go func() { time.Sleep(50 * time.Millisecond); annuleer() }()

	got, err := r.client(t).BackupVM(ctx, "7")
	if err != nil {
		t.Fatalf("BackupVM: %v", err)
	}
	if got.VolID != "local:backup/vzdump-qemu-7-nu.vma.zst" {
		t.Fatalf("verkeerd archief: %q", got.VolID)
	}
}

// Maar een archief van vóór deze back-up is van een vorige ronde. Dat als
// uitkomst melden zou de klant een herstelpunt tonen dat zijn wijzigingen van
// vandaag niet bevat, en het zou de back-up van vandaag als gelukt boeken.
func TestBackupVMNeemtGeenOuderArchief(t *testing.T) {
	r := newRecorder(t)
	r.on("POST /nodes/pve/vzdump", okTask)
	r.on("GET /nodes/pve/tasks/UPID:pve:0000:OK::task/status", `{"data":{"status":"running"}}`)
	r.on("GET /nodes/pve/storage/local/content", fmt.Sprintf(
		`{"data":[{"volid":"local:backup/vzdump-qemu-7-gisteren.vma.zst","size":9,"ctime":%d}]}`,
		time.Now().Unix()-86400))

	ctx, annuleer := context.WithCancel(context.Background())
	go func() { time.Sleep(50 * time.Millisecond); annuleer() }()

	if _, err := r.client(t).BackupVM(ctx, "7"); err == nil {
		t.Fatal("een archief van gisteren werd voor de back-up van nu aangezien")
	}
}
