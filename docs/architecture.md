# Architecture & Roadmap

Bunk Fleet powers a **multi-node VPS platform**: a central control plane
orchestrates a fleet of worker nodes, all of them Bunk's own hardware. There is
no third-party capacity and no customer-operated node — a customer picks a
region and a package, and the control plane decides which of our nodes runs it.

## The four problem layers

1. **Compute** — creating, running, and destroying VMs across our hypervisors
   (Proxmox, ESXi/vCenter) on hardware that may sit behind NAT.
2. **Scheduling** — deciding *where* a customer's VPS runs: honouring the
   user-chosen region and packing onto the node that keeps the most headroom.
3. **Connectivity** — giving VPS instances routable public endpoints regardless
   of a node's local network.
4. **High availability** — keeping the control plane and the fleet running
   through node failures and control-plane restarts.

## Chosen stack

| Concern               | Choice                          | Why                                                              |
| --------------------- | ------------------------------- | --------------------------------------------------------------- |
| Control plane         | **Elixir / Phoenix (OTP)**      | Many concurrent flaky-agent connections, realtime console mux, supervision/fault-tolerance. |
| Worker agent          | **Go (few deps: govmomi, websocket)** | Single static binary, trivial to ship to a new node.            |
| Hypervisors           | **Proxmox** + **ESXi/vCenter**  | What our nodes actually run.                                    |
| Reaching a VPS        | **Relayed through its node's agent** | The agent already dials out; nothing has to reach in.      |
| Persistence           | **Postgres** (via Ecto)         | Authoritative inventory, placement, and billing state.          |
| Agent authentication  | **Per-node bearer token**       | Minted once at enrollment; only its hash is stored.             |

## Trust model

Every node is ours, so there is no untrusted class of hardware to fence off and
no per-node trust tier. The security boundary that matters is between
**tenants**: a customer must never reach another customer's VM, console, or
billing data. That is enforced in the control plane (owner-scoped queries,
server-set VPS ownership, CP-allocated console IPs, host-key pinning), not by
sorting nodes into tiers.

Node enrollment is therefore an **internal ops action**: an admin mints a
single-use enroll token, the agent redeems it once, and the node gets a
long-lived agent token. Nodes are attributed to a **cost centre**
(`nodes.owner_email`) so we can see which hardware carried which load — this is
internal cost accounting, not a payout.

## Scheduling: region + resources

The customer **picks a region**. The control plane filters to healthy nodes in
that region that fit the request, locking the candidate rows `FOR UPDATE` so
concurrent placements cannot oversell the same node, then places the VPS on the
node that would be left with the **most headroom** (scored across vCPU/RAM/disk).
Capacity is reserved against the node on placement and reconciled against
subsequent heartbeats.

Because RAM is the resource that cannot be overcommitted safely, RAM is in
practice the binding constraint on how many VPS instances a node can carry.

## Reaching a VPS from the control plane

The control plane never opens a connection to a node. A node can be behind NAT,
behind CGNAT, or on a school network, and nothing about that changes what works.

When the browser console needs a VPS, the control plane queues a request on the
channel the node's agent is already polling; the agent dials back over WSS and
relays bytes to the VPS's SSH port. The control plane needs no route to the
node's private network and no public address of its own.

There was a WireGuard overlay here. It never carried a byte — enrolment handed
out keys, but no hub ever listened, and the endpoint it advertised resolved to a
CDN that does not carry UDP. It was removed rather than finished, because the
relay solves the problem it was for and solves it in more places.

Customer *inbound* access — someone reaching their own VPS from the internet —
is a separate, still-open problem: see `docs/design/multi-node.md` §3.2.

## Failure modes

- **Node offline** (heartbeats go stale) → the control plane marks the node
  offline, **drains** its scheduling eligibility, and stops metering its VPS
  instances, since a node that isn't reporting isn't delivering.
- **Agent crash / restart** → the agent reconnects with its persisted token and
  **reconciles** running VMs against the control plane's expected state
  (heartbeat `running_vms` vs inventory).
- **Control-plane restart** → OTP supervision restarts processes; agents
  reconnect with backoff; Postgres remains the source of truth so no placement
  state is lost.
- **Capacity drift** → heartbeats continuously correct the scheduler's view of
  available resources.

## Phased roadmap

- **F1 — Node-aware refactor.** *(done)* Model nodes, regions, capacity, and
  placement in the control plane.
- **F2 — Agent + enrollment.** *(done)* `bunk-agent`, single-use-token
  enrollment, per-node agent tokens, heartbeats, command long-poll.
- **F3 — Console.** *(done)* End-to-end console with host-key pinning, relayed
  through the node's own agent so it works on a node we cannot dial.
- **F4 — Fleet operations.** Running more than one node well: capacity
  planning against real cost per node, node drain/maintenance mode, backups,
  and per-node cost reporting.
- **F5 — Control-plane HA.** Highly-available control plane and resilient
  secret management.
