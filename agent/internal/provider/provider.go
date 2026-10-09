// Package provider defines the hypervisor-abstraction contract used by the
// bunk-agent. A concrete provider (Proxmox, Incus, ...) wraps a local
// hypervisor and exposes a small, uniform surface for provisioning,
// deleting, inspecting and reporting capacity of virtual machines.
//
// All implementations MUST be safe for concurrent use and MUST honour the
// supplied context.Context for cancellation and deadlines.
package provider

import "context"

// VMSpec is the desired-state description of a virtual machine that the
// control plane asks the agent to provision. It is hypervisor-agnostic; each
// provider maps these fields onto its native API.
type VMSpec struct {
	// Name is the human-readable / DNS-safe name of the guest.
	Name string `json:"name"`
	// VCPU is the number of virtual CPU cores to allocate.
	VCPU int `json:"vcpu"`
	// RAMMB is the amount of memory to allocate, in megabytes.
	RAMMB int `json:"ram_mb"`
	// DiskGB is the size of the primary disk, in gigabytes.
	DiskGB int `json:"disk_gb"`
	// TemplateID identifies the source template/image to clone from. Its
	// meaning is provider-specific (e.g. a Proxmox VMID template).
	TemplateID int `json:"template_id"`
	// CloudInit holds extra cloud-init key/value pairs (e.g. user, password
	// hash, custom metadata) merged into the generated config.
	CloudInit map[string]string `json:"cloud_init"`
	// SSHKeys is the list of authorized public SSH keys injected via cloud-init.
	SSHKeys []string `json:"ssh_keys"`
	// IPConfig is a provider-native network configuration string
	// (e.g. Proxmox "ip=192.0.2.10/24,gw=192.0.2.1" or "ip=dhcp").
	IPConfig string `json:"ip_config"`
	// VPSID is the control plane's id for this machine. It is written onto the
	// guest (Proxmox: the description) so a later delete can check that it is
	// destroying the machine it was asked to destroy, and not whatever guest now
	// happens to carry that VMID. Empty when the control plane did not send one.
	VPSID string `json:"vps_id"`
	// RateMbit caps the guest's network interface, in megabits per second, and
	// is the snelheid that belongs to the customer's package. Zero means no cap:
	// a VPS created without a package should not get an invented limit.
	//
	// It is a ceiling enforced by the hypervisor, not guaranteed throughput --
	// the uplink is shared. Only applied when the guest is created; an existing
	// VPS keeps what it has.
	RateMbit int `json:"rate_mbit"`
}

// VMStatus is the observed state of a virtual machine.
type VMStatus struct {
	// ID is the provider-native identifier of the guest (e.g. a Proxmox VMID
	// as a string).
	ID string `json:"id"`
	// State is a normalized lifecycle string such as "running", "stopped",
	// "provisioning" or "unknown".
	State string `json:"state"`
	// IP is the primary IPv4 address of the guest, if known/assigned.
	IP string `json:"ip"`
}

// Capacity is a best-effort snapshot of the resources of the underlying node,
// used to build heartbeat reports for the control plane scheduler.
type Capacity struct {
	TotalVCPU   int
	AvailVCPU   int
	TotalRAMMB  int
	AvailRAMMB  int
	TotalDiskGB int
	AvailDiskGB int
}

// Provider is the abstraction over a local hypervisor.
type Provider interface {
	// CreateVM provisions a new guest from the given spec and returns its
	// initial status. It should be effectively idempotent where the backend
	// allows, and must return a non-nil error if provisioning cannot start.
	CreateVM(ctx context.Context, spec VMSpec) (VMStatus, error)

	// DeleteVM stops (if necessary) and destroys the guest identified by id.
	// Deleting a non-existent guest should be treated as success.
	//
	// `vpsID` is the control plane's id for the machine that is supposed to be
	// destroyed. A hypervisor id (a Proxmox VMID) is reused once a guest is gone,
	// so a delete that is redelivered after that number has been handed to
	// another customer would destroy THEIR machine. Providers that can see who a
	// guest belongs to must refuse in that case. Empty means "no claim" -- a
	// guest from before this check existed -- and then the id is all there is.
	DeleteVM(ctx context.Context, id string, vpsID string) error

	// StatusVM returns the current observed status of the guest identified by id.
	StatusVM(ctx context.Context, id string) (VMStatus, error)

	// ListGuestIDs returns every guest this node knows about, by provider-native
	// id. Not for scheduling -- for comparing the control plane's administration
	// with what actually runs.
	//
	// Both directions matter. A VPS that we bill for and that no longer exists
	// costs a customer money for nothing; a guest on the node that we do not know
	// about eats capacity we think we can still sell, and nobody will ever clean
	// it up because nothing points at it.
	//
	// It must FAIL rather than return an empty list when the hypervisor cannot be
	// reached. "Everything is gone" and "I cannot see anything" look identical in
	// an empty slice, and acting on the first when it was the second would delete
	// a fleet.
	ListGuestIDs(ctx context.Context) ([]string, error)

	// FindByName looks up a guest by its (unique) guest name and returns its
	// status. The boolean reports whether a matching guest was found: it is
	// true with a populated VMStatus when a match exists, and false with a zero
	// VMStatus when no guest carries that name. A non-nil error indicates the
	// lookup itself failed (e.g. the backend was unreachable) and the other
	// return values must be ignored.
	//
	// It exists so callers can make provisioning idempotent: before creating a
	// VM they can check whether one with the desired name already exists and, if
	// so, adopt it instead of creating a duplicate.
	FindByName(ctx context.Context, name string) (VMStatus, bool, error)

	// Capacity returns a best-effort snapshot of node resources.
	Capacity(ctx context.Context) (Capacity, error)

	// PowerOn starts a stopped guest. Idempotent: a no-op if already running.
	PowerOn(ctx context.Context, id string) error

	// PowerOff stops a running guest. Idempotent: a no-op if already stopped.
	PowerOff(ctx context.Context, id string) error

	// Reboot restarts a running guest from the inside: the operating system is
	// asked to shut down and comes back up. Deliberately NOT a hard reset --
	// that is pulling the power on a customer's disk, and the explicit way to
	// get it is PowerOff followed by PowerOn.
	//
	// Fails rather than starts a guest that is not running: "reboot" on a
	// stopped machine means the caller thinks it is running, and quietly doing
	// something else hides that.
	Reboot(ctx context.Context, id string) error

	// Suspend pauses (suspend-to-RAM) a running guest. Idempotent if already paused.
	Suspend(ctx context.Context, id string) error

	// Resume un-pauses a suspended guest. Idempotent if already running.
	Resume(ctx context.Context, id string) error

	// Name returns the short provider identifier, e.g. "proxmox".
	Name() string
}

// Backups is implemented by providers that can archive a guest's disk.
//
// Separate from Provider on purpose. Backing up a Proxmox guest and backing up
// an ESXi guest are different mechanisms with different storage, so a provider
// that cannot do it should say so by not implementing this — rather than by
// growing a method that returns "not supported" and looking capable in the type
// system.
type Backups interface {
	// BackupVM archives the guest's disk to the node's own storage and returns a
	// provider-native handle on the archive plus its size in bytes.
	BackupVM(ctx context.Context, id string) (Backup, error)

	// DeleteBackup removes an archive by the handle BackupVM returned. Deleting
	// one that is already gone is success.
	DeleteBackup(ctx context.Context, volid string) error

	// RestoreVM overwrites the guest's disk with an archive, replacing whatever
	// is there now. The guest is left stopped; the caller decides whether to
	// start it, because only the caller knows what state the customer had it in.
	RestoreVM(ctx context.Context, id, volid string) error
}

// Backup is what a provider hands back after archiving a guest.
type Backup struct {
	// VolID is the provider's own identifier for the archive, opaque to everyone
	// else — e.g. "local:backup/vzdump-qemu-106-2026_09_11-20_15_00.vma.zst".
	VolID string
	// SizeBytes is the archive's size on the node's storage.
	SizeBytes int64
}

// Settings are the runtime knobs the control plane may change while the agent is
// running. A zero value means "not configured": the provider keeps whatever it
// was started with, so a node nobody has touched keeps behaving as it did.
type Settings struct {
	VCPUOversubscribe int
	VMIDMin           int
	VMIDMax           int
	// Bridge is de bridge waar de NIC van een nieuwe VPS aan komt te hangen.
	// Leeg = niet ingesteld: de provider houdt wat er bij het starten stond.
	Bridge string
	// VLAN met een aparte vlag, want 0 is hier een geldige waarde (untagged) en
	// dus niet te gebruiken als "niet ingesteld".
	VLAN          int
	VLANIngesteld bool
}

// Configurable is implemented by providers that accept settings at runtime.
// Optional on purpose: a provider that has nothing to configure simply does not
// implement it, and the caller skips it.
type Configurable interface {
	ApplySettings(Settings)
}

// Afscherming is wat een provider kan zeggen over hoe goed klanten op deze node
// van elkaar gescheiden zijn. Optioneel: de agent vraagt het alleen als de
// provider het kent. Een lege notitie betekent "afgeschermd"; anders staat er
// voor de eigenaar van de node wat er ontbreekt.
type Afscherming interface {
	Afscherming(ctx context.Context) (string, error)
}
