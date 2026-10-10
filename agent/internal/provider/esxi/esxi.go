// Package esxi implements provider.Provider against VMware vSphere/ESXi using
// govmomi. VMs are cloned from a template; cloud-init is delivered via guestinfo
// (the VMware datasource). Each operation opens a short-lived session so there is
// no long-lived connection to keep healthy. ESXi support is built and
// simulator-tested; live validation on a real host comes later (Proxmox-first).
package esxi

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/vmware/govmomi"
	"github.com/vmware/govmomi/find"
	"github.com/vmware/govmomi/object"
	"github.com/vmware/govmomi/property"
	"github.com/vmware/govmomi/vim25/mo"
	"github.com/vmware/govmomi/vim25/soap"
	"github.com/vmware/govmomi/vim25/types"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
)

// Config holds vSphere/ESXi connection + placement parameters.
type Config struct {
	URL          string // e.g. https://vcenter.example.com/sdk
	User         string
	Password     string
	Insecure     bool
	Datacenter   string // optional; default datacenter when empty
	Datastore    string // optional; default datastore when empty
	ResourcePool string // optional; default pool when empty
	Folder       string // optional; default VM folder when empty
	Template     string // required: name of the template VM to clone
}

// Client is a stateless vSphere provider; it connects per operation.
type Client struct{ cfg Config }

func New(cfg Config) (*Client, error) {
	switch {
	case cfg.URL == "":
		return nil, errors.New("esxi: url is required")
	case cfg.User == "" || cfg.Password == "":
		return nil, errors.New("esxi: user and password are required")
	case cfg.Template == "":
		return nil, errors.New("esxi: template is required")
	}
	return &Client{cfg: cfg}, nil
}

func (c *Client) Name() string { return "esxi" }

func (c *Client) connect(ctx context.Context) (*govmomi.Client, error) {
	u, err := url.Parse(c.cfg.URL)
	if err != nil {
		return nil, fmt.Errorf("esxi: bad url: %w", err)
	}
	u.User = url.UserPassword(c.cfg.User, c.cfg.Password)
	return govmomi.NewClient(ctx, u, c.cfg.Insecure)
}

func (c *Client) finder(ctx context.Context, gc *govmomi.Client) (*find.Finder, error) {
	f := find.NewFinder(gc.Client, true)

	var (
		dc  *object.Datacenter
		err error
	)
	if c.cfg.Datacenter != "" {
		dc, err = f.Datacenter(ctx, c.cfg.Datacenter)
	} else {
		dc, err = f.DefaultDatacenter(ctx)
	}
	if err != nil {
		return nil, fmt.Errorf("esxi: datacenter: %w", err)
	}

	f.SetDatacenter(dc)
	return f, nil
}

func vmByID(gc *govmomi.Client, id string) *object.VirtualMachine {
	return object.NewVirtualMachine(gc.Client, types.ManagedObjectReference{Type: "VirtualMachine", Value: id})
}

// isNotFound reports whether err means "that guest is not here", which the
// delete path treats as success: delete commands are re-delivered, and the
// second one finds nothing.
//
// errors.As rather than a type assertion, because this package wraps with %w
// everywhere — a bare assertion misses a NotFound that travelled through one
// fmt.Errorf and turns "already gone" into a failure the VPS never recovers
// from. The string check stays last: some govmomi paths return a plain error
// with no type to match on.
func isNotFound(err error) bool {
	if err == nil {
		return false
	}

	var notFound *find.NotFoundError
	if errors.As(err, &notFound) {
		return true
	}

	// govmomi's soap fault carrier is unexported, so errors.As has nothing to
	// target; IsSoapFault does a bare assertion of its own. Walk the chain and
	// ask it at each level instead, which is the same thing errors.As would do
	// if the type were exported.
	for e := err; e != nil; e = errors.Unwrap(e) {
		if !soap.IsSoapFault(e) {
			continue
		}
		switch soap.ToSoapFault(e).VimFault().(type) {
		case types.ManagedObjectNotFound, *types.ManagedObjectNotFound:
			return true
		}
		break
	}

	// De tekstcontrole alleen voor een antwoord van vSphere zelf. Een fout op
	// transportniveau, of een HTTP-404 van een proxy of een verkeerd /sdk-pad,
	// bevat ook "not found" -- en dan meldde een verwijdering "klaar" terwijl de
	// VM er nog stond, en gaf de inventaris een lege lijst: "alles is weg".
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		return false
	}
	msg := strings.ToLower(err.Error())
	if strings.Contains(msg, "404") {
		return false
	}
	return strings.Contains(msg, "not found")
}

// CreateVM clones the configured template into a new powered-on VM.
func (c *Client) CreateVM(ctx context.Context, spec provider.VMSpec) (provider.VMStatus, error) {
	gc, err := c.connect(ctx)
	if err != nil {
		return provider.VMStatus{}, err
	}
	defer logout(ctx, gc)

	f, err := c.finder(ctx, gc)
	if err != nil {
		return provider.VMStatus{}, err
	}

	tmpl, err := f.VirtualMachine(ctx, c.cfg.Template)
	if err != nil {
		return provider.VMStatus{}, fmt.Errorf("esxi: template %q: %w", c.cfg.Template, err)
	}

	ds, err := f.DatastoreOrDefault(ctx, c.cfg.Datastore)
	if err != nil {
		return provider.VMStatus{}, fmt.Errorf("esxi: datastore: %w", err)
	}
	pool, err := f.ResourcePoolOrDefault(ctx, c.cfg.ResourcePool)
	if err != nil {
		return provider.VMStatus{}, fmt.Errorf("esxi: resource pool: %w", err)
	}
	folder, err := f.FolderOrDefault(ctx, c.cfg.Folder)
	if err != nil {
		return provider.VMStatus{}, fmt.Errorf("esxi: folder: %w", err)
	}

	dsRef := ds.Reference()
	poolRef := pool.Reference()
	metadata, userdata := cloudInit(spec)

	configSpec := &types.VirtualMachineConfigSpec{
		NumCPUs:  int32(spec.VCPU),
		MemoryMB: int64(spec.RAMMB),
		ExtraConfig: []types.BaseOptionValue{
			&types.OptionValue{Key: "guestinfo.metadata", Value: base64.StdEncoding.EncodeToString([]byte(metadata))},
			&types.OptionValue{Key: "guestinfo.metadata.encoding", Value: "base64"},
			&types.OptionValue{Key: "guestinfo.userdata", Value: base64.StdEncoding.EncodeToString([]byte(userdata))},
			&types.OptionValue{Key: "guestinfo.userdata.encoding", Value: "base64"},
		},
	}

	// Grow the primary disk to the requested size during the clone so the customer
	// gets the disk they paid for instead of the template's size. A disk can only
	// be grown, never shrunk; a smaller-or-equal request keeps the template size.
	if spec.DiskGB > 0 {
		diskChange, err := growDiskSpec(ctx, tmpl, spec.DiskGB)
		if err != nil {
			return provider.VMStatus{}, err
		}
		if diskChange != nil {
			configSpec.DeviceChange = []types.BaseVirtualDeviceConfigSpec{diskChange}
		}
	}

	cloneSpec := types.VirtualMachineCloneSpec{
		Location: types.VirtualMachineRelocateSpec{Datastore: &dsRef, Pool: &poolRef},
		Config:   configSpec,
		PowerOn:  true,
		Template: false,
	}

	task, err := tmpl.Clone(ctx, folder, spec.Name, cloneSpec)
	if err != nil {
		return provider.VMStatus{}, fmt.Errorf("esxi: clone: %w", err)
	}
	info, err := task.WaitForResult(ctx, nil)
	if err != nil {
		// The clone may still be running server-side; roll back the (possibly
		// partial) VM by name so it isn't orphaned — mirrors the Proxmox provider.
		// If cleanup can't destroy it, surface its ref so the control plane can
		// reconcile the orphan rather than losing track of it.
		orphan := c.rollbackClone(spec.Name)
		return provider.VMStatus{ID: orphan, State: "error"}, fmt.Errorf("esxi: clone task: %w", err)
	}

	ref, ok := info.Result.(types.ManagedObjectReference)
	if !ok {
		return provider.VMStatus{}, errors.New("esxi: clone returned no VM reference")
	}
	return provider.VMStatus{ID: ref.Value, State: "provisioning"}, nil
}

// growDiskSpec returns a device-edit that grows the template's primary disk to
// diskGB, or nil when the template disk is already at least that big (never
// shrinks). Errors if the template has no disk to grow.
func growDiskSpec(ctx context.Context, tmpl *object.VirtualMachine, diskGB int) (types.BaseVirtualDeviceConfigSpec, error) {
	devices, err := tmpl.Device(ctx)
	if err != nil {
		return nil, fmt.Errorf("esxi: read template devices: %w", err)
	}

	disks := devices.SelectByType((*types.VirtualDisk)(nil))
	if len(disks) == 0 {
		return nil, errors.New("esxi: template has no virtual disk to resize")
	}
	disk, ok := disks[0].(*types.VirtualDisk)
	if !ok {
		return nil, errors.New("esxi: unexpected virtual disk device type")
	}

	targetKB := int64(diskGB) * 1024 * 1024
	if disk.CapacityInKB >= targetKB {
		return nil, nil
	}
	disk.CapacityInKB = targetKB

	return &types.VirtualDeviceConfigSpec{
		Operation: types.VirtualDeviceConfigSpecOperationEdit,
		Device:    disk,
	}, nil
}

// rollbackClone best-effort destroys a VM left behind by a failed clone, on a
// fresh detached session (the caller's ctx may be the deadline that killed the
// clone). Returns "" when the VM was never created or was cleaned up, or its ref
// when it exists but could not be destroyed (so the CP can reconcile it).
func (c *Client) rollbackClone(name string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	gc, err := c.connect(ctx)
	if err != nil {
		return ""
	}
	defer logout(ctx, gc)

	f, err := c.finder(ctx, gc)
	if err != nil {
		return ""
	}
	vm, err := f.VirtualMachine(ctx, name)
	if err != nil {
		return "" // never created (or already gone): nothing to roll back
	}

	ref := vm.Reference().Value
	if derr := c.DeleteVM(ctx, ref, ""); derr != nil {
		return ref
	}
	return ""
}

// DeleteVM negeert `vpsID`: op vSphere schrijven we (nog) niet op de gast wie
// hij is, dus er valt niets te controleren. Dat is een gat en geen keuze -- de
// Proxmox-provider weigert wél een gast die bij iemand anders hoort. Zolang dat
// hier niet kan, is de id alles wat we hebben.
func (c *Client) DeleteVM(ctx context.Context, id string, _ string) error {
	gc, err := c.connect(ctx)
	if err != nil {
		return err
	}
	defer logout(ctx, gc)

	vm := vmByID(gc, id)

	state, err := vm.PowerState(ctx)
	if err != nil {
		if isNotFound(err) {
			return nil // already gone
		}
		return fmt.Errorf("esxi: power state: %w", err)
	}

	// Zie de Proxmox-provider: een mislukte stop is nog geen reden om op te
	// geven, maar hij hoort wel in de fout als de destroy daarna faalt.
	var stopFout error
	if state != types.VirtualMachinePowerStatePoweredOff {
		if t, err := vm.PowerOff(ctx); err != nil {
			stopFout = err
		} else if err := t.Wait(ctx); err != nil {
			stopFout = err
		}
	}

	t, err := vm.Destroy(ctx)
	if err != nil {
		if isNotFound(err) {
			return nil
		}
		if stopFout != nil {
			return fmt.Errorf("esxi: destroy: %w (daarvoor mislukte het uitzetten al: %v)", err, stopFout)
		}
		return fmt.Errorf("esxi: destroy: %w", err)
	}
	return t.Wait(ctx)
}

func (c *Client) StatusVM(ctx context.Context, id string) (provider.VMStatus, error) {
	gc, err := c.connect(ctx)
	if err != nil {
		return provider.VMStatus{}, err
	}
	defer logout(ctx, gc)

	vm := vmByID(gc, id)
	return statusOf(ctx, gc, vm, id)
}

func (c *Client) FindByName(ctx context.Context, name string) (provider.VMStatus, bool, error) {
	gc, err := c.connect(ctx)
	if err != nil {
		return provider.VMStatus{}, false, err
	}
	defer logout(ctx, gc)

	f, err := c.finder(ctx, gc)
	if err != nil {
		return provider.VMStatus{}, false, err
	}

	vm, err := f.VirtualMachine(ctx, name)
	if err != nil {
		if isNotFound(err) {
			return provider.VMStatus{}, false, nil
		}
		return provider.VMStatus{}, false, err
	}

	st, err := statusOf(ctx, gc, vm, vm.Reference().Value)
	if err != nil {
		return provider.VMStatus{}, false, err
	}
	return st, true, nil
}

func statusOf(ctx context.Context, gc *govmomi.Client, vm *object.VirtualMachine, id string) (provider.VMStatus, error) {
	var mvm mo.VirtualMachine
	pc := property.DefaultCollector(gc.Client)
	if err := pc.RetrieveOne(ctx, vm.Reference(), []string{"summary.runtime", "guest"}, &mvm); err != nil {
		return provider.VMStatus{}, fmt.Errorf("esxi: status: %w", err)
	}

	ip := ""
	if mvm.Guest != nil {
		ip = mvm.Guest.IpAddress
	}
	return provider.VMStatus{ID: id, State: normalizeState(mvm.Summary.Runtime.PowerState), IP: ip}, nil
}

func normalizeState(s types.VirtualMachinePowerState) string {
	switch s {
	case types.VirtualMachinePowerStatePoweredOn:
		return "running"
	case types.VirtualMachinePowerStatePoweredOff:
		return "stopped"
	case types.VirtualMachinePowerStateSuspended:
		return "paused"
	default:
		return "unknown"
	}
}

func (c *Client) PowerOn(ctx context.Context, id string) error  { return c.power(ctx, id, "on") }
func (c *Client) PowerOff(ctx context.Context, id string) error { return c.power(ctx, id, "off") }
func (c *Client) Suspend(ctx context.Context, id string) error  { return c.power(ctx, id, "suspend") }
func (c *Client) Resume(ctx context.Context, id string) error   { return c.power(ctx, id, "on") }

// ListGuestIDs implements provider.Provider: elke VM die deze vSphere/ESXi
// kent, bij zijn managed-object id -- hetzelfde id dat `statusOf` als VMStatus.ID
// teruggeeft, zodat de vergelijking met de administratie op gelijke waarden gaat.
//
// Faalt wanneer vSphere niet bereikbaar is. Een lege lijst zou daar niet van te
// onderscheiden zijn, en "alles is weg" is een gevaarlijke conclusie om te
// trekken uit "ik kan even niet kijken".
func (c *Client) ListGuestIDs(ctx context.Context) ([]string, error) {
	gc, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}
	defer logout(ctx, gc)

	f, err := c.finder(ctx, gc)
	if err != nil {
		return nil, err
	}

	vms, err := f.VirtualMachineList(ctx, "*")
	if err != nil {
		if isNotFound(err) {
			// Geen VM's is een geldig antwoord van een bereikbare vSphere.
			return []string{}, nil
		}
		return nil, fmt.Errorf("esxi: list guests: %w", err)
	}

	ids := make([]string, 0, len(vms))
	for _, vm := range vms {
		ids = append(ids, vm.Reference().Value)
	}
	sort.Strings(ids)

	return ids, nil
}

// Reboot implements provider.Provider: the guest OS is asked to restart, through
// VMware Tools. Without Tools there is no way to ask politely, and the
// alternative -- vm.Reset -- is pulling the power on a customer's disk; that
// stays an explicit stop followed by a start rather than something that happens
// silently behind the word "reboot".
func (c *Client) Reboot(ctx context.Context, id string) error {
	gc, err := c.connect(ctx)
	if err != nil {
		return err
	}
	defer logout(ctx, gc)

	vm := vmByID(gc, id)
	state, err := vm.PowerState(ctx)
	if err != nil {
		return fmt.Errorf("esxi: power state: %w", err)
	}
	if state != types.VirtualMachinePowerStatePoweredOn {
		return fmt.Errorf("esxi: guest is %s, not powered on: cannot reboot", state)
	}
	if err := vm.RebootGuest(ctx); err != nil {
		return fmt.Errorf("esxi: reboot guest (are VMware Tools running?): %w", err)
	}
	return nil
}

func (c *Client) power(ctx context.Context, id, op string) error {
	gc, err := c.connect(ctx)
	if err != nil {
		return err
	}
	defer logout(ctx, gc)

	vm := vmByID(gc, id)
	state, err := vm.PowerState(ctx)
	if err != nil {
		return fmt.Errorf("esxi: power state: %w", err)
	}

	var task *object.Task
	switch op {
	case "on":
		if state == types.VirtualMachinePowerStatePoweredOn {
			return nil
		}
		task, err = vm.PowerOn(ctx)
	case "off":
		if state == types.VirtualMachinePowerStatePoweredOff {
			return nil
		}
		task, err = vm.PowerOff(ctx)
	case "suspend":
		if state != types.VirtualMachinePowerStatePoweredOn {
			return nil
		}
		task, err = vm.Suspend(ctx)
	default:
		return fmt.Errorf("esxi: unknown power op %q", op)
	}
	if err != nil {
		return fmt.Errorf("esxi: power %s: %w", op, err)
	}
	return task.Wait(ctx)
}

func (c *Client) Capacity(ctx context.Context) (provider.Capacity, error) {
	gc, err := c.connect(ctx)
	if err != nil {
		return provider.Capacity{}, err
	}
	defer logout(ctx, gc)

	f, err := c.finder(ctx, gc)
	if err != nil {
		return provider.Capacity{}, err
	}

	host, err := f.DefaultHostSystem(ctx)
	if err != nil {
		hosts, e := f.HostSystemList(ctx, "*")
		if e != nil || len(hosts) == 0 {
			return provider.Capacity{}, fmt.Errorf("esxi: host: %w", err)
		}
		host = hosts[0]
	}

	pc := property.DefaultCollector(gc.Client)

	var hs mo.HostSystem
	if err := pc.RetrieveOne(ctx, host.Reference(), []string{"summary", "datastore", "vm"}, &hs); err != nil {
		return provider.Capacity{}, fmt.Errorf("esxi: host props: %w", err)
	}

	totalVCPU, totalRAM := 0, 0
	if hs.Summary.Hardware != nil {
		totalVCPU = int(hs.Summary.Hardware.NumCpuThreads)
		totalRAM = int(hs.Summary.Hardware.MemorySize / (1024 * 1024))
	}

	usedVCPU, usedRAM := 0, 0
	if len(hs.Vm) > 0 {
		var vms []mo.VirtualMachine
		// Zie de Proxmox-provider: zonder VM-lijst is het gebruik onbekend, niet nul.
		if err := pc.Retrieve(ctx, hs.Vm, []string{"summary.config", "summary.runtime"}, &vms); err != nil {
			return provider.Capacity{}, fmt.Errorf("esxi: vm-lijst ophalen voor de capaciteit: %w", err)
		}
		for _, vm := range vms {
			if vm.Summary.Runtime.PowerState == types.VirtualMachinePowerStatePoweredOn {
				usedVCPU += int(vm.Summary.Config.NumCpu)
				usedRAM += int(vm.Summary.Config.MemorySizeMB)
			}
		}
	}

	totalDisk, availDisk := 0, 0
	if len(hs.Datastore) > 0 {
		var dss []mo.Datastore
		if err := pc.Retrieve(ctx, hs.Datastore, []string{"summary"}, &dss); err == nil {
			for _, d := range dss {
				totalDisk += int(d.Summary.Capacity / (1024 * 1024 * 1024))
				availDisk += int(d.Summary.FreeSpace / (1024 * 1024 * 1024))
			}
		}
	}

	return provider.Capacity{
		TotalVCPU:   totalVCPU,
		AvailVCPU:   nonNeg(totalVCPU - usedVCPU),
		TotalRAMMB:  totalRAM,
		AvailRAMMB:  nonNeg(totalRAM - usedRAM),
		TotalDiskGB: totalDisk,
		AvailDiskGB: availDisk,
	}, nil
}

func nonNeg(n int) int {
	if n < 0 {
		return 0
	}
	return n
}

// singleLine returns s only if it contains no CR/LF, else "" — used to keep
// user-supplied values from injecting extra lines into the cloud-config YAML.
func singleLine(s string) string {
	if strings.ContainsAny(s, "\r\n") {
		return ""
	}
	return s
}

// yamlQuote wraps a value in single quotes so YAML reads it as the literal text.
//
// Newlines are already refused by singleLine, wat het ergste geval afdekt. Maar
// een wachtwoord als `{a: b}` wordt zonder aanhalingstekens een map, `*iets` een
// verwijzing naar een anchor, `waarde # nog wat` verliest alles achter het hekje,
// en `ja` wordt een boolean. Dat is geen inbraak -- de waarde komt van ons eigen
// control plane -- maar het is wel een klant die niet kan inloggen op de VPS die
// hij net besteld heeft, om een reden die niemand aan de buitenkant ziet.
//
// Binnen enkele aanhalingstekens betekent YAML niets meer, op het aanhalingsteken
// zelf na; dat wordt verdubbeld.
func yamlQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// cloudInit builds guestinfo metadata + userdata (NoCloud-style) from the spec.
func cloudInit(spec provider.VMSpec) (metadata, userdata string) {
	var b strings.Builder
	b.WriteString("#cloud-config\n")

	// Only single-line SSH keys: a key containing a newline would break out of the
	// YAML list item and inject arbitrary cloud-config below it.
	var keys []string
	for _, k := range spec.SSHKeys {
		if k != "" && !strings.ContainsAny(k, "\r\n") {
			keys = append(keys, k)
		}
	}
	if len(keys) > 0 {
		b.WriteString("ssh_authorized_keys:\n")
		for _, k := range keys {
			b.WriteString("  - ")
			b.WriteString(k)
			b.WriteString("\n")
		}
	}

	// Password login for the cloud-init user, mirroring the Proxmox provider's
	// ciuser/cipassword so an ESXi VPS isn't left SSH-key-only. Both values are
	// validated single-line to keep them from injecting extra YAML.
	user := singleLine(spec.CloudInit["user"])
	pass := singleLine(spec.CloudInit["password"])
	if user != "" && pass != "" {
		b.WriteString("ssh_pwauth: true\n")
		b.WriteString("chpasswd:\n  expire: false\n  users:\n")
		b.WriteString("    - name: ")
		b.WriteString(yamlQuote(user))
		b.WriteString("\n      password: ")
		b.WriteString(yamlQuote(pass))
		b.WriteString("\n      type: text\n")
	}

	userdata = b.String()

	var m strings.Builder
	m.WriteString("instance-id: ")
	m.WriteString(spec.Name)
	m.WriteString("\nlocal-hostname: ")
	m.WriteString(spec.Name)
	m.WriteString("\n")
	if net := networkConfig(spec.IPConfig); net != "" {
		m.WriteString(net)
	}
	metadata = m.String()
	return metadata, userdata
}

// networkConfig converts a Proxmox-style "ip=A.B.C.D/PFX,gw=G" into cloud-init
// network-config v2. Returns "" for dhcp/empty/unparseable input.
func networkConfig(ipConfig string) string {
	if ipConfig == "" || strings.Contains(ipConfig, "dhcp") {
		return ""
	}

	var ipcidr, gw string
	for _, part := range strings.Split(ipConfig, ",") {
		part = strings.TrimSpace(part)
		switch {
		case strings.HasPrefix(part, "ip="):
			ipcidr = strings.TrimPrefix(part, "ip=")
		case strings.HasPrefix(part, "gw="):
			gw = strings.TrimPrefix(part, "gw=")
		}
	}
	if ipcidr == "" {
		return ""
	}

	var b strings.Builder
	b.WriteString("network:\n  version: 2\n  ethernets:\n    id0:\n      match:\n        name: e*\n      addresses:\n        - ")
	b.WriteString(ipcidr)
	b.WriteString("\n")
	if gw != "" {
		b.WriteString("      gateway4: ")
		b.WriteString(gw)
		b.WriteString("\n")
	}
	return b.String()
}

// Afscherming: deze provider schermt klanten op één host niet van elkaar af. Er
// zijn geen regels per gast, zoals bij Proxmox, en een port group laat gasten
// elkaar op laag 2 gewoon zien. Dat hoort de eigenaar van de node te weten
// voordat hij er klanten op zet, niet achteraf.
func (c *Client) Afscherming(context.Context) (string, error) {
	return "ESXi schermt klanten op deze node niet van elkaar af; zet de VPS'en op een " +
		"port group met private VLAN's of gebruik deze node voor één klant", nil
}

// logout sluit een vCenter/ESXi-sessie, ook als de context van de handeling al
// verlopen is. Juist dan was het fout gegaan: Logout(ctx) faalde direct op de
// verlopen context en de sessie bleef op de host openstaan. Een trage host liet
// zo elke hartslag een sessie achter, tot hostd zijn maximum bereikte en ook
// een operator er niet meer in kon.
func logout(ctx context.Context, gc *govmomi.Client) {
	lctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	_ = gc.Logout(lctx)
}
