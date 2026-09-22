package proxmox

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

// compile-time assertion that Client can archive a guest's disk.
var _ provider.Backups = (*Client)(nil)

// backupStorage is where archives go when the operator has not said otherwise.
// "local" is the storage every PVE install has, and the one a single-node setup
// actually uses.
const backupStorage = "local"

// BackupVM archives the guest with `vzdump`.
//
// Mode is `snapshot`: the guest keeps running. `stop` would give a marginally
// more consistent archive at the cost of taking a customer's machine down every
// night, which is not a trade anyone would accept for a backup they hope never
// to need.
// Hoelang we hoogstens nog zoeken naar een archief nadat het wachten is
// afgebroken. Eén listing; duurt dat langer, dan praat de node niet meer.
const archiefZoekGrens = 10 * time.Second

func (c *Client) BackupVM(ctx context.Context, id string) (provider.Backup, error) {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return provider.Backup{}, fmt.Errorf("proxmox: backup: %q is not a vmid", id)
	}

	storage := c.backupStorage()

	form := url.Values{
		"vmid":     {strconv.Itoa(vmid)},
		"storage":  {storage},
		"mode":     {"snapshot"},
		"compress": {"zstd"},
		// remove=0: retention is the control plane's decision, made from rows it
		// can show a customer. Letting PVE prune on its own count would delete
		// archives the control plane still believes in.
		"remove": {"0"},
	}

	// Het moment waarop dit begon. Een archief dat hierna is ontstaan kan alleen
	// van deze aanroep zijn; een ouder archief is van een vorige back-up en mag
	// nooit voor de onze doorgaan.
	begonnen := time.Now().Unix()

	var task taskResponse
	path := fmt.Sprintf("/nodes/%s/vzdump", c.cfg.Node)
	if err := c.doJSON(ctx, http.MethodPost, path, form, &task); err != nil {
		return provider.Backup{}, fmt.Errorf("proxmox: vzdump vm %d: %w", vmid, err)
	}
	if err := c.waitTask(ctx, task.Data); err != nil {
		// Proxmox werkt door als wij ophouden met kijken. Wordt de agent
		// herstart terwijl er een back-up loopt, dan valt het commando weg, maar
		// de vzdump loopt op de node gewoon af en laat een archief achter.
		//
		// Melden wij dan enkel "mislukt", dan gebeuren er twee dingen. De klant
		// leest dat zijn back-up niet is gelukt terwijl hij er wel staat. En
		// erger: het control plane kent alleen archieven waarvan het de volid
		// heeft, dus dat bestand heeft vanaf dat moment geen handvat meer en kan
		// door niemand nog worden opgeruimd. Zo bleef er twee gigabyte staan van
		// machines die allang weg waren.
		//
		// Daarom eerst kijken of er alsnog een archief is verschenen. Zo ja, dan
		// is de back-up gelukt en melden we dat -- met de volid, zodat hij later
		// ook weer weg kan.
		if archief, gevonden := c.archiefSinds(ctx, storage, vmid, begonnen); gevonden {
			return archief, nil
		}

		return provider.Backup{}, fmt.Errorf("proxmox: vzdump vm %d: %w", vmid, err)
	}

	// vzdump's task does not report which file it produced, so ask the storage
	// for this guest's archives and take the newest. Scoped to the vmid, so a
	// backup of some other guest finishing at the same moment cannot be mistaken
	// for ours.
	archive, err := c.newestBackup(ctx, storage, vmid)
	if err != nil {
		return provider.Backup{}, err
	}
	return archive, nil
}

// DeleteBackup removes one archive. An archive that is already gone is success:
// the control plane is asking for it not to exist, and it does not.
func (c *Client) DeleteBackup(ctx context.Context, volid string) error {
	storage, err := storageOf(volid)
	if err != nil {
		return err
	}

	path := fmt.Sprintf("/nodes/%s/storage/%s/content/%s",
		c.cfg.Node, url.PathEscape(storage), url.PathEscape(volid))

	var task taskResponse
	if err := c.doJSON(ctx, http.MethodDelete, path, nil, &task); err != nil {
		if isNotFound(err) {
			return nil
		}
		return fmt.Errorf("proxmox: delete backup %s: %w", volid, err)
	}
	// Deleting a file usually completes inline; when PVE hands back a task, wait.
	if task.Data != "" {
		if err := c.waitTask(ctx, task.Data); err != nil {
			return fmt.Errorf("proxmox: delete backup %s: %w", volid, err)
		}
	}
	return nil
}

type storageContent struct {
	Data []struct {
		VolID string `json:"volid"`
		Size  int64  `json:"size"`
		CTime int64  `json:"ctime"`
		VMID  any    `json:"vmid"`
	} `json:"data"`
}

// archiefSinds zoekt een archief van deze gast dat ná `sinds` is ontstaan.
//
// Draait bewust op een LOSSE context: dit wordt aangeroepen juist wanneer de
// oorspronkelijke is afgebroken, en met die context zou de vraag meteen weer
// stuklopen. De grens is kort -- het is één listing, en als de node op dit
// moment niet praat, is er niets meer te redden.
func (c *Client) archiefSinds(ctx context.Context, storage string, vmid int, sinds int64) (provider.Backup, bool) {
	los, annuleer := context.WithTimeout(context.WithoutCancel(ctx), archiefZoekGrens)
	defer annuleer()

	path := fmt.Sprintf("/nodes/%s/storage/%s/content?content=backup&vmid=%d",
		c.cfg.Node, url.PathEscape(storage), vmid)

	var out storageContent
	if err := c.doJSON(los, http.MethodGet, path, nil, &out); err != nil {
		return provider.Backup{}, false
	}

	sort.Slice(out.Data, func(i, j int) bool { return out.Data[i].CTime > out.Data[j].CTime })
	for _, kandidaat := range out.Data {
		if kandidaat.CTime >= sinds {
			return provider.Backup{VolID: kandidaat.VolID, SizeBytes: kandidaat.Size}, true
		}
	}

	return provider.Backup{}, false
}

func (c *Client) newestBackup(ctx context.Context, storage string, vmid int) (provider.Backup, error) {
	path := fmt.Sprintf("/nodes/%s/storage/%s/content?content=backup&vmid=%d",
		c.cfg.Node, url.PathEscape(storage), vmid)

	var out storageContent
	if err := c.doJSON(ctx, http.MethodGet, path, nil, &out); err != nil {
		return provider.Backup{}, fmt.Errorf("proxmox: list backups: %w", err)
	}
	if len(out.Data) == 0 {
		// The task said it succeeded and the storage has nothing. Reporting
		// success here would record a backup that does not exist, which is worse
		// than reporting a failure that did not happen.
		return provider.Backup{}, fmt.Errorf("proxmox: vzdump reported success but %s holds no archive for %d", storage, vmid)
	}

	sort.Slice(out.Data, func(i, j int) bool { return out.Data[i].CTime > out.Data[j].CTime })
	newest := out.Data[0]
	return provider.Backup{VolID: newest.VolID, SizeBytes: newest.Size}, nil
}

func (c *Client) backupStorage() string {
	if s := strings.TrimSpace(c.cfg.BackupStorage); s != "" {
		return s
	}
	return backupStorage
}

// storageOf pulls the storage name out of a volid ("local:backup/vzdump-…").
// Rejecting a malformed one matters: the value is interpolated into an API path.
func storageOf(volid string) (string, error) {
	name, rest, found := strings.Cut(volid, ":")
	if !found || name == "" || rest == "" || strings.ContainsAny(name, "/ \t") {
		return "", fmt.Errorf("proxmox: %q is not a storage volume identifier", volid)
	}
	return name, nil
}

// isNotFound reports whether an API error was a 404 — PVE's answer for an
// archive that is no longer there.
func isNotFound(err error) bool {
	return err != nil && strings.Contains(err.Error(), "status 404")
}

// RestoreVM overwrites the guest's disk from an archive.
//
// The guest is stopped first — `qmrestore` refuses to touch a running VM, and
// for good reason: it is replacing the disk underneath it. It is left stopped
// afterwards. Whether it should be running again is the control plane's
// decision, because only it knows what state the customer had it in.
//
// This destroys whatever is on the disk now. Everything that makes that safe —
// ownership, an archive that belongs to this VPS, a customer who was told — has
// happened before the command reached here.
func (c *Client) RestoreVM(ctx context.Context, id, volid string) error {
	vmid, err := strconv.Atoi(id)
	if err != nil {
		return fmt.Errorf("proxmox: restore: %q is not a vmid", id)
	}
	if _, err := storageOf(volid); err != nil {
		return err
	}

	if err := c.PowerOff(ctx, id); err != nil {
		return fmt.Errorf("proxmox: restore vm %d: stopping it first: %w", vmid, err)
	}

	form := url.Values{
		"vmid":    {strconv.Itoa(vmid)},
		"archive": {volid},
		// force: the guest exists and is exactly what we mean to replace.
		"force": {"1"},
		// Leave it down. Whether it should be running again is the control
		// plane's call, because only it knows what the customer had.
		"start": {"0"},
	}

	// The guest-create endpoint, not /qmrestore: `qmrestore` is a CLI command
	// with no API route of its own (PVE answers 501 for it — learned the hard
	// way against a live node). Creating a guest *with* an `archive` parameter
	// is how the API spells a restore.
	var task taskResponse
	path := fmt.Sprintf("/nodes/%s/qemu", c.cfg.Node)
	if err := c.doJSON(ctx, http.MethodPost, path, form, &task); err != nil {
		return fmt.Errorf("proxmox: restore vm %d: %w", vmid, err)
	}
	if err := c.waitTask(ctx, task.Data); err != nil {
		return fmt.Errorf("proxmox: restore vm %d: %w", vmid, err)
	}
	return nil
}
