// Command bunk-agent is the worker-node agent of the Bunk multi-node VPS
// hosting platform. It talks to a local hypervisor (Proxmox first), dials out
// to the control plane, enrolls with a one-time token, and reports capacity
// heartbeats on a timer until interrupted.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/config"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider/esxi"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/provider/proxmox"
	"github.com/Bunk-Hosting/bunk-fleet/agent/internal/transport"
)

// version is stamped in at build time with -ldflags "-X main.version=...".
// The fallback matters: a binary built by hand reports something honest rather
// than claiming to be a release it is not.
var version = "onbekend"

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if err := run(logger); err != nil {
		logger.Error("bunk-agent exited with error", "err", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	// Root context cancelled on SIGINT/SIGTERM for graceful shutdown.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Build the hypervisor provider.
	prov, err := buildProvider(cfg)
	if err != nil {
		return err
	}
	logger.Info("provider initialized", "provider", prov.Name(), "hypervisor", cfg.Hypervisor)

	// Control-plane client.
	cp := transport.New(cfg.ControlPlaneURL, nil)

	// Credentials: prefer persisted enrollment (survives restarts) over consuming
	// a fresh single-use token; only enroll when no state exists yet.
	statePath := filepath.Join(cfg.StateDir, "state.json")
	// Held past the branches below: the console target check needs the VPS subnet
	// the control plane assigned, whether this run enrolled or resumed.
	var state persistedState
	if st, ok := loadState(statePath); ok {
		state = st
		cp.SetCredentials(st.NodeID, st.AgentToken)
		logger.Info("loaded persisted enrollment", "node_id", st.NodeID)
		applyVpsNetwork(logger, cfg.VpsNetwork.Bridge, vpsNetwerkVan(st, cfg.VpsNetwork), cfg.ManageNetwork)
	} else if cfg.EnrollToken != "" {
		enrollCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		resp, err := cp.Enroll(enrollCtx, cfg.EnrollToken, cfg.Hypervisor, cfg.OwnerEmail, transport.VpsNetwork{
			Gateway:    cfg.VpsNetwork.Gateway,
			CidrPrefix: cfg.VpsNetwork.CidrPrefix,
			RangeStart: cfg.VpsNetwork.RangeStart,
			RangeEnd:   cfg.VpsNetwork.RangeEnd,
		})
		cancel()
		if err != nil {
			return err
		}
		logger.Info("enrolled with control plane", "node_id", resp.NodeID)

		st := persistedState{NodeID: resp.NodeID, AgentToken: resp.AgentToken}
		if resp.VpsNetwork != nil {
			st.VpsGateway = resp.VpsNetwork.Gateway
			st.VpsCidrPrefix = resp.VpsNetwork.CidrPrefix
			logger.Info("control plane assigned the VPS network",
				"gateway", resp.VpsNetwork.Gateway,
				"prefix", resp.VpsNetwork.CidrPrefix,
				"range", resp.VpsNetwork.RangeStart+"-"+resp.VpsNetwork.RangeEnd)
		}
		if err := saveState(statePath, st); err != nil {
			logger.Warn("could not persist enrollment; a restart will need a fresh token", "err", err)
		}
		applyVpsNetwork(logger, cfg.VpsNetwork.Bridge, vpsNetwerkVan(st, cfg.VpsNetwork), cfg.ManageNetwork)
		state = st
	} else {
		logger.Warn("no enroll token and no persisted state; heartbeats will fail until credentials are set")
	}

	// Command consumer: long-poll the control plane for provision/delete
	// commands and execute them concurrently with the heartbeat loop. Requires
	// credentials, so it is only started once enrolled.
	if cp.NodeID() != "" {
		cmds, err := cp.Commands(ctx)
		if err != nil {
			return err
		}
		subnet := assignedSubnet(state, cfg.VpsNetwork)
		go consumeCommands(ctx, logger, prov, cp, cmds, subnet, cfg.ParallelCommands())
		logger.Info("command consumer started")

		// Inbound access for this node's customers. Its own loop rather than a
		// command, because it is state to converge on, not an event to react to.
		go syncForwards(ctx, logger, cp, subnet, cfg.ManageNetwork)
	} else {
		logger.Warn("not enrolled; command consumer not started")
	}

	offer := &offerHolder{v: cfg.Offer}

	// Heartbeat loop.
	ticker := time.NewTicker(cfg.HeartbeatInterval)
	defer ticker.Stop()

	logger.Info("starting heartbeat loop", "interval", cfg.HeartbeatInterval.String())

	// Send an immediate first heartbeat, then on each tick.
	sendHeartbeat(ctx, logger, prov, cp, offer)

	for {
		select {
		case <-ctx.Done():
			logger.Info("shutdown signal received, stopping")
			return nil
		case <-ticker.C:
			sendHeartbeat(ctx, logger, prov, cp, offer)
		}
	}
}

// buildProvider constructs the hypervisor provider selected by cfg.Hypervisor.
func buildProvider(cfg config.Config) (provider.Provider, error) {
	switch cfg.Hypervisor {
	case "esxi":
		return esxi.New(esxi.Config{
			URL:          cfg.Esxi.URL,
			User:         cfg.Esxi.User,
			Password:     cfg.Esxi.Password,
			Insecure:     cfg.Esxi.Insecure,
			Datacenter:   cfg.Esxi.Datacenter,
			Datastore:    cfg.Esxi.Datastore,
			ResourcePool: cfg.Esxi.ResourcePool,
			Folder:       cfg.Esxi.Folder,
			Template:     cfg.Esxi.Template,
		})
	default:
		return proxmox.New(proxmox.Config{
			BackupStorage:     cfg.Proxmox.BackupStorage,
			VCPUOversubscribe: cfg.Proxmox.VCPUOversubscribe,
			VMIDMin:           cfg.Proxmox.VMIDMin,
			VMIDMax:           cfg.Proxmox.VMIDMax,
			Host:              cfg.Proxmox.Host,
			Node:              cfg.Proxmox.Node,
			TokenID:           cfg.Proxmox.TokenID,
			TokenSecret:       cfg.Proxmox.TokenSecret,
			VerifySSL:         cfg.Proxmox.VerifySSL,
			Fingerprint:       cfg.Proxmox.Fingerprint,
			Bridge:            cfg.VpsNetwork.Bridge,
			VLAN:              cfg.VpsNetwork.VLAN,
		})
	}
}

// capOffer caps advertised capacity to the configured VPS-pool size (0 per
// dimension = unlimited), clamping availability so the scheduler never sees
// more free capacity than is actually offered.
func capOffer(c provider.Capacity, o config.OfferConfig) provider.Capacity {
	if o.VCPU > 0 && c.TotalVCPU > o.VCPU {
		c.TotalVCPU = o.VCPU
	}
	if c.AvailVCPU > c.TotalVCPU {
		c.AvailVCPU = c.TotalVCPU
	}
	if o.RAMMB > 0 && c.TotalRAMMB > o.RAMMB {
		c.TotalRAMMB = o.RAMMB
	}
	if c.AvailRAMMB > c.TotalRAMMB {
		c.AvailRAMMB = c.TotalRAMMB
	}
	if o.DiskGB > 0 && c.TotalDiskGB > o.DiskGB {
		c.TotalDiskGB = o.DiskGB
	}
	if c.AvailDiskGB > c.TotalDiskGB {
		c.AvailDiskGB = c.TotalDiskGB
	}
	return c
}

// offerHolder houdt hoeveel van deze machine naar de pool gaat. Het wordt
// geschreven door de heartbeat-lus en gelezen door diezelfde lus, maar via een
// slot omdat de waarde ook uit een antwoord van de control plane kan komen en
// het aantal lezers later kan groeien.
type offerHolder struct {
	mu sync.RWMutex
	v  config.OfferConfig
}

func (o *offerHolder) get() config.OfferConfig {
	o.mu.RLock()
	defer o.mu.RUnlock()
	return o.v
}

func (o *offerHolder) set(v config.OfferConfig) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.v = v
}

// applySettings neemt over wat de control plane meestuurt. Een nul betekent
// "niet ingesteld" en laat staan wat er lokaal is geconfigureerd -- niets
// ingesteld hebben is iets anders dan op nul zetten, en alleen dat laatste hoort
// het gedrag van een node te veranderen.
func applySettings(logger *slog.Logger, prov provider.Provider, offer *offerHolder, s transport.NodeSettings) {
	huidig := offer.get()
	nieuw := config.OfferConfig{
		VCPU:   kies(s.OfferVCPU, huidig.VCPU),
		RAMMB:  kies(s.OfferRAMMB, huidig.RAMMB),
		DiskGB: kies(s.OfferDiskGB, huidig.DiskGB),
	}
	if nieuw != huidig {
		logger.Info("aanbod bijgesteld vanuit het dashboard",
			"vcpu", nieuw.VCPU, "ram_mb", nieuw.RAMMB, "disk_gb", nieuw.DiskGB)
		offer.set(nieuw)
	}

	if c, ok := prov.(provider.Configurable); ok {
		nieuw := provider.Settings{
			VCPUOversubscribe: s.VCPUOversubscribe,
			VMIDMin:           s.VMIDMin,
			VMIDMax:           s.VMIDMax,
		}
		if s.Bridge != nil {
			nieuw.Bridge = *s.Bridge
		}
		if s.VLAN != nil {
			nieuw.VLAN, nieuw.VLANIngesteld = *s.VLAN, true
		}
		// Ook loggen als er niets aan het aanbod verandert. Zonder deze regel is
		// "heeft die node zijn instellingen nou opgepakt?" een vraag die niemand
		// kan beantwoorden: een VMID-bereik of een overboekingsfactor landde stil.
		if nieuw != vorigeProviderSettings {
			logger.Info("instellingen opgehaald uit het dashboard",
				"vmid_min", nieuw.VMIDMin,
				"vmid_max", nieuw.VMIDMax,
				"vcpu_per_core", nieuw.VCPUOversubscribe,
				"bridge", nieuw.Bridge,
				"vlan", nieuw.VLAN)
			vorigeProviderSettings = nieuw
		}
		c.ApplySettings(nieuw)
	}
}

// Wat er de vorige keer naar de provider ging, alleen om te kunnen zien wanneer
// er iets verandert. Wordt uitsluitend vanuit de heartbeat-lus aangeraakt.
var vorigeProviderSettings provider.Settings

func kies(vanCP, lokaal int) int {
	if vanCP > 0 {
		return vanCP
	}
	return lokaal
}

// sendHeartbeat collects capacity from the provider and reports it to the
// control plane. Errors are logged but never fatal: a single failed heartbeat
// must not take the agent down.
func sendHeartbeat(ctx context.Context, logger *slog.Logger, prov provider.Provider, cp *transport.Client, offer *offerHolder) {
	hbCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	hb := transport.Heartbeat{
		NodeID:  cp.NodeID(),
		At:      time.Now().UTC(),
		Version: version,
	}

	// A failed capacity query used to return here, which meant no heartbeat at
	// all. The control plane then saw the same thing it sees for a machine that
	// is switched off, and marked the node offline after two minutes -- hiding
	// the fact that the agent is alive and that the hypervisor API is the
	// problem. Report the failure instead: the node stays visible, and the
	// control plane zeroes what it may schedule on it.
	capacity, err := prov.Capacity(hbCtx)
	if err != nil {
		logger.Error("capacity query failed", "err", err)
		hb.CapacityError = capacityReason(err)
	} else {
		capacity = capOffer(capacity, offer.get())
		hb.TotalVCPU = capacity.TotalVCPU
		hb.AvailVCPU = capacity.AvailVCPU
		hb.TotalRAMMB = capacity.TotalRAMMB
		hb.AvailRAMMB = capacity.AvailRAMMB
		hb.TotalDiskGB = capacity.TotalDiskGB
		hb.AvailDiskGB = capacity.AvailDiskGB
	}

	settings, err := cp.SendHeartbeat(hbCtx, hb)
	if err != nil {
		logger.Error("heartbeat send failed", "err", err)
		return
	}

	// Wat de eigenaar in het dashboard heeft gezet, toegepast op de volgende
	// ronde. Het antwoord komt elke keer mee, dus een wijziging landt binnen een
	// interval zonder dat iemand op deze machine hoeft in te loggen.
	applySettings(logger, prov, offer, settings)
	if hb.CapacityError != "" {
		logger.Info("heartbeat sent without capacity", "reason", hb.CapacityError)
		return
	}
	logger.Info("heartbeat sent",
		"avail_vcpu", capacity.AvailVCPU,
		"avail_ram_mb", capacity.AvailRAMMB,
		"avail_disk_gb", capacity.AvailDiskGB,
	)
}

// capacityReason turns a provider error into something an operator can act on
// in the panel. It is trimmed because the column is bounded and a wall of text
// is not more useful than its first line -- the agent's own log has the rest.
func capacityReason(err error) string {
	// Ruim onder de kolombreedte in het control plane. Een reden die daar niet
	// in past laat de hele heartbeat afketsen, en dan staat de node dood in het
	// paneel om een foutmelding die te lang was.
	const maxLen = 240

	reason := strings.TrimSpace(err.Error())
	if reason == "" {
		reason = "onbekende fout bij het opvragen van de capaciteit"
	}
	if len(reason) > maxLen {
		// Op een tekengrens en niet op een byte. Een afgesneden rune is geen
		// geldige UTF-8 meer, en Postgres weigert dat -- waarmee dezelfde
		// heartbeat alsnog omvalt. Het beletselteken maakt zichtbaar dat er
		// iets is weggelaten.
		afgekapt := reason[:maxLen]
		for len(afgekapt) > 0 && !utf8.ValidString(afgekapt) {
			afgekapt = afgekapt[:len(afgekapt)-1]
		}
		reason = strings.TrimRight(afgekapt, " ") + "\u2026"
	}
	return reason
}

// consumeCommands drains the command channel until it is closed (on context
// cancellation or a fatal poll error) and dispatches each command. A panic or
// failure handling one command must not stop the loop.
func consumeCommands(ctx context.Context, logger *slog.Logger, prov provider.Provider, cp *transport.Client, cmds <-chan transport.Command, assigned *net.IPNet, parallel int) {
	// Replay protection. A MITM on a cleartext channel (or a buggy CP) could
	// re-deliver a previously-seen command — e.g. replay a delete{vm_id} after
	// that VMID has been reassigned to another tenant. Each Command.ID is executed
	// at most once (bounded FIFO so the set can't grow without limit) — but a
	// redelivery of a FINISHED command is answered with the result it produced,
	// because the control plane only asks again when it never got one. See
	// commandMemos.
	const maxSeen = 1024
	memos := newCommandMemos(maxSeen)

	// Commando's voor verschillende VPS'en lopen naast elkaar, voor dezelfde VPS
	// op volgorde. Zie werkers.go voor waarom dat onderscheid nodig is.
	banen := nieuweWerkers(parallel, func(cmd transport.Command) {
		handleCommand(ctx, logger, prov, cp, memos, cmd)
	})
	// Bij het stoppen eerst het lopende werk laten aflopen. Het kost niets: de
	// context is dan al afgelopen, dus elk commando dat nog draait valt binnen
	// een tel om en meldt dat het mislukt is. Dat laatste is precies de winst --
	// een commando dat stilzwijgend verdwijnt laat het control plane wachten tot
	// de herleverings-TTL.
	defer banen.wacht()

	for {
		select {
		case <-ctx.Done():
			logger.Info("command consumer stopping", "reason", ctx.Err())
			return
		case cmd, ok := <-cmds:
			if !ok {
				logger.Info("command stream closed")
				return
			}
			if prior := memos.accept(cmd.ID); prior != nil {
				if prior.done {
					// The control plane is asking again because it never got the
					// answer. Give it the same one rather than doing the work twice
					// — or, worse, staying silent and leaving the command wedged.
					logger.Info("re-reporting a result the control plane did not receive",
						"id", cmd.ID, "kind", string(cmd.Kind), "status", prior.result.Status)
					reportResult(ctx, logger, cp, memos, cmd.ID, prior.result)
				} else {
					logger.Info("command already running; its result is still coming",
						"id", cmd.ID, "kind", string(cmd.Kind))
				}
				continue
			}
			// A console request is not a command: nothing converges, nothing is
			// reported, and it must not sit inside handleCommand's 15-minute
			// budget while a person waits for a terminal.
			if cmd.Kind == transport.CmdConsoleConnect {
				handleConsoleConnect(ctx, logger, cp, assigned, cmd.Payload)
				continue
			}

			banen.stuur(cmd)
		}
	}
}

// handleCommand executes a single dispatched command and reports its outcome to
// the control plane. All errors are turned into a "failed" result; they are
// never propagated so a single bad command cannot take the agent down.
func handleCommand(parentCtx context.Context, logger *slog.Logger, prov provider.Provider, cp *transport.Client, memos *commandMemos, cmd transport.Command) {
	// Bound every command so a hung hypervisor task (e.g. a stuck PVE clone)
	// can't make a provider call poll forever and wedge the consumer.
	ctx, cancel := context.WithTimeout(parentCtx, 15*time.Minute)
	defer cancel()

	// A panic in any provider/govmomi path must not crash the whole agent
	// (which would kill heartbeats + the command stream). Recover, report the
	// command failed on a DETACHED context, and keep the loop alive.
	defer func() {
		if r := recover(); r != nil {
			rctx, rcancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer rcancel()
			logger.Error("command handler panicked", "id", cmd.ID, "kind", string(cmd.Kind), "panic", r)
			reportResult(rctx, logger, cp, memos, cmd.ID, transport.CommandResult{Status: "failed", Error: fmt.Sprintf("agent panic: %v", r)})
		}
	}()

	logger.Info("command received", "id", cmd.ID, "kind", string(cmd.Kind))

	c := command{ctx: ctx, logger: logger, prov: prov, cp: cp, memos: memos, cmd: cmd}

	switch cmd.Kind {
	case transport.CmdProvision:
		handleProvision(c)

	case transport.CmdDelete:
		handleDelete(c)

	case transport.CmdBackup, transport.CmdDeleteBackup, transport.CmdRestoreBackup:
		handleBackupCommand(ctx, logger, prov, cp, memos, cmd)

	case transport.CmdStart, transport.CmdStop, transport.CmdPause, transport.CmdResume,
		transport.CmdReboot:
		handlePower(c)

	case transport.CmdInventory:
		handleInventory(c)

	case transport.CmdUpdate:
		handleUpdate(c)

	default:
		logger.Warn("unknown command kind; ignoring", "id", cmd.ID, "kind", string(cmd.Kind))
		c.report(transport.CommandResult{Status: "failed", Error: "unknown command kind: " + string(cmd.Kind)})
	}
}

// command is one dispatched instruction plus everything handling it needs. It
// exists so the handlers below can say `c.report(...)` instead of threading five
// unchanging arguments through every one of their exits — and they have many
// exits, because every step of talking to a hypervisor can fail.
type command struct {
	ctx    context.Context
	logger *slog.Logger
	prov   provider.Provider
	cp     *transport.Client
	memos  *commandMemos
	cmd    transport.Command
}

func (c command) report(res transport.CommandResult) {
	reportResult(c.ctx, c.logger, c.cp, c.memos, c.cmd.ID, res)
}

// failed reports the command failed and logs why. `vmID` is empty when there is
// no guest to point at yet; when there is one, it must be carried so the control
// plane can reconcile whatever was left behind.
func (c command) failed(msg string, vmID string, err error) {
	c.logger.Error(msg, "id", c.cmd.ID, "kind", string(c.cmd.Kind), "vm_id", vmID, "err", err)
	c.report(transport.CommandResult{Status: "failed", VMID: vmID, Error: err.Error()})
}

func handleProvision(c command) {
	var spec provider.VMSpec
	if err := json.Unmarshal(c.cmd.Payload, &spec); err != nil {
		c.failed("provision: bad payload", "", err)
		return
	}
	// De payload draagt hem ook, maar het commando is de bron: daar staat over
	// welke VPS dit gaat, ongeacht wat er in de payload is meegestuurd.
	if c.cmd.VPSID != "" {
		spec.VPSID = c.cmd.VPSID
	}

	c.logger.Info("provisioning vm", "id", c.cmd.ID, "name", spec.Name)

	// Idempotency: the control plane may re-deliver a provision command (e.g.
	// after an agent crash before the result was reported). If a guest with this
	// name already exists, adopt it instead of cloning a duplicate.
	existing, found, err := c.prov.FindByName(c.ctx, spec.Name)
	if err != nil {
		c.failed("provision: existing-vm lookup failed", "", err)
		return
	}
	if found {
		adoptExisting(c, spec, existing)
		return
	}

	st, err := c.prov.CreateVM(c.ctx, spec)
	if err != nil {
		// st.ID is set when a partial VM could not be rolled back, so the control
		// plane can still reconcile/delete the orphan.
		c.failed("provision failed", st.ID, err)
		return
	}
	c.logger.Info("provision done", "id", c.cmd.ID, "vm_id", st.ID, "ip", st.IP)
	c.report(transport.CommandResult{Status: "done", VMID: st.ID, IP: st.IP})
}

// A guest with this name already exists, but FindByName only reports its
// list-level state and never an IP. A previous attempt may have crashed
// mid-flight (clone→resize→config→start), leaving the guest stopped or
// half-configured. Re-check its real state and IP before adopting it, so a
// broken VPS is never marked active.
func adoptExisting(c command, spec provider.VMSpec, existing provider.VMStatus) {
	c.logger.Info("vm already exists (idempotent)", "id", c.cmd.ID, "name", spec.Name, "vm_id", existing.ID)

	status, err := c.prov.StatusVM(c.ctx, existing.ID)
	if err != nil {
		c.failed("provision: status of existing vm failed", existing.ID, err)
		return
	}

	if status.State == "running" {
		c.logger.Info("adopted existing vm", "id", c.cmd.ID, "vm_id", status.ID, "ip", status.IP)
		c.report(transport.CommandResult{Status: "done", VMID: status.ID, IP: status.IP})
		return
	}

	// Stopped or half-configured: fail so the control plane drives a clean retry
	// (which can delete and re-provision) rather than adopting it.
	c.logger.Warn("existing vm not running; not adopting", "id", c.cmd.ID, "vm_id", status.ID, "state", status.State)
	c.report(transport.CommandResult{
		Status: "failed",
		VMID:   status.ID,
		Error:  "existing vm in state " + status.State + " (not running)",
	})
}

func handleDelete(c command) {
	vmID, ok := payloadVMID(c, "delete")
	if !ok {
		return
	}

	c.logger.Info("deleting vm", "id", c.cmd.ID, "vm_id", vmID)
	// De VPS-id gaat mee zodat de provider kan weigeren als dit VMID intussen
	// aan een andere klant toebehoort. Zie Provider.DeleteVM.
	if err := c.prov.DeleteVM(c.ctx, vmID, c.cmd.VPSID); err != nil {
		c.failed("delete failed", vmID, err)
		return
	}
	c.logger.Info("delete done", "id", c.cmd.ID, "vm_id", vmID)
	c.report(transport.CommandResult{Status: "done", VMID: vmID})
}

// handleUpdate kicks off the self-update and reports success immediately.
//
// The order is the whole point. The updater restarts this very process, so
// anything reported after starting it would never be sent — the command would
// sit in-flight until it timed out and was redelivered, and the node would
// update itself again on every poll. Reporting first, then handing the work to
// systemd, means the restart happens to a process that has already said what it
// needed to say.
//
// --no-block matters for the same reason: without it systemctl waits for the
// unit to finish, and that unit stops this service.
func handleUpdate(c command) {
	if _, err := exec.LookPath("systemctl"); err != nil {
		c.report(transport.CommandResult{Status: "failed", Error: "systemctl not available on this node"})
		return
	}

	if _, err := os.Stat(updateUnitPath); err != nil {
		c.report(transport.CommandResult{
			Status: "failed",
			Error:  "updater not installed on this node; run the agent-update bootstrap first",
		})
		return
	}

	c.report(transport.CommandResult{Status: "done"})

	c.logger.Info("update requested; handing over to systemd")
	if err := exec.Command("systemctl", "start", "--no-block", updateUnitName).Run(); err != nil {
		// Reporting again is not possible — the result is already in. A log line
		// is what is left, and it is enough: the node keeps running the binary it
		// has, and the nightly timer tries again.
		c.logger.Error("could not start the updater", "err", err)
	}
}

const (
	updateUnitName = "bunk-agent-update.service"
	updateUnitPath = "/etc/systemd/system/bunk-agent-update.service"
)

func handlePower(c command) {
	vmID, ok := payloadVMID(c, "power")
	if !ok {
		return
	}

	var err error
	switch c.cmd.Kind {
	case transport.CmdStart:
		err = c.prov.PowerOn(c.ctx, vmID)
	case transport.CmdStop:
		err = c.prov.PowerOff(c.ctx, vmID)
	case transport.CmdPause:
		err = c.prov.Suspend(c.ctx, vmID)
	case transport.CmdResume:
		err = c.prov.Resume(c.ctx, vmID)
	case transport.CmdReboot:
		err = c.prov.Reboot(c.ctx, vmID)
	}
	if err != nil {
		c.failed("power command failed", vmID, err)
		return
	}
	c.logger.Info("power command done", "id", c.cmd.ID, "kind", string(c.cmd.Kind), "vm_id", vmID)
	c.report(transport.CommandResult{Status: "done", VMID: vmID})
}

// handleInventory antwoordt met elk gast-id dat deze node kent.
//
// Dit is het enige commando dat niets verandert. Het bestaat omdat de
// administratie en de werkelijkheid uit elkaar kunnen lopen zonder dat iets dat
// merkt: een VM die met de hand van de hypervisor is verwijderd blijft in de
// database staan en wordt gefactureerd, en een VM die wij ooit hebben
// aangemaakt maar kwijt zijn geraakt eet capaciteit die wij denken te kunnen
// verkopen.
//
// Een fout wordt als fout gemeld en niet als een lege lijst. "Alles is weg" en
// "ik kan even niet kijken" zien er in een lege lijst hetzelfde uit, en het
// control plane mag op het eerste niet handelen als het het tweede was.
func handleInventory(c command) {
	ids, err := c.prov.ListGuestIDs(c.ctx)
	if err != nil {
		c.failed("inventory", "", err)
		return
	}

	c.logger.Info("inventory reported", "id", c.cmd.ID, "guests", len(ids))
	c.report(transport.CommandResult{Status: "done", Guests: ids})
}

// Every command that acts on an existing guest carries its id the same way.
// Returns false once the failure has already been reported.
func payloadVMID(c command, what string) (string, bool) {
	var payload struct {
		VMID string `json:"vm_id"`
	}
	if err := json.Unmarshal(c.cmd.Payload, &payload); err != nil {
		c.failed(what+": bad payload", "", err)
		return "", false
	}
	return payload.VMID, true
}

// reportResult posts a command outcome with a bounded timeout, logging (but not
// propagating) any reporting failure.
func reportResult(ctx context.Context, logger *slog.Logger, cp *transport.Client, memos *commandMemos, commandID string, res transport.CommandResult) {
	// Detach from the command's own deadline before applying a fresh 15s cap.
	// The command context carries a 15-MINUTE ceiling (handleCommand); when a
	// command actually hits that ceiling — the exact "hung hypervisor" case the
	// timeout exists for — `ctx` is already expired, so deriving the report
	// context from it would fail instantly and the "failed" outcome would never
	// reach the control plane. WithoutCancel strips the deadline while retaining
	// request-scoped values.
	//
	// A send that still fails is survivable now: the result is memoised first, so
	// the control plane's next redelivery is answered with it instead of being
	// dropped as a duplicate.
	rptCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	defer cancel()
	// Remember it before trying to send. A report that fails is exactly the case
	// the memo exists for: the control plane will ask again, and the answer has to
	// still be here when it does.
	memos.record(commandID, res)

	if err := cp.ReportResult(rptCtx, commandID, res); err != nil {
		logger.Error("report result failed", "id", commandID, "status", res.Status, "err", err)
	}
}
