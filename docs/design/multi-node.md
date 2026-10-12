# Design — one control plane, many resource nodes, several regions

*Status: proposal. Written 2026-09-12 against commit `d987b4c`. Every "today"
claim below was verified against the live system, not inferred from the code.*

The target: one control plane; multiple resource nodes carrying customer VPSes;
nodes grouped into regions; a customer may state a region preference, and when
they don't, the platform places the VPS on a node that has room. Customers never
see a node.

That is the right shape, and the codebase is already built for it. The work is
not a redesign. It is closing a small number of gaps, in an order that matters
more than the gaps themselves.

---

## 1. Where we actually are

### 1.1 It is one physical machine

Everything runs on `CP-NL1-01`:

| | |
|---|---|
| VM 102 | control plane, Postgres, frontend, edge |
| VM 106 | **a running customer VPS** |
| VM 100 | the router (OpenWRT) — gateway for the VPS network |
| LXC 103 | the Cloudflare tunnel |
| LXC 104 | the marketing site |
| LXC 101 | the worker agent that manages the nodes |

One disk, one PSU, one kernel panic and all of it goes at once: control plane,
database, router, tunnel, website, and the customer's server.

This matters more than it looks. The architecture separates control plane from
data plane correctly — the agent is autonomous, VPSes survive a control-plane
restart — but **that separation does not exist physically**. "VPSes keep running
when the control plane is down" is true of the code and false of the deployment.

Everything else in this document is downstream of that.

### 1.2 The fleet

One region, `nl-1`. Two nodes, both in it:

- `node-7p04lMHBqk0` (Proxmox, online): 4 vCPU / 11.8 GB / 93 GB, of which
  **1 vCPU, 8.7 GB and 33 GB are free**
- `node-o0-9YLe_NZY` (ESXi): offline since 10 July

One active VPS, one stopped, three accounts.

The online node cannot fit a Pro (4/8/80) — there is 33 GB of disk left. Of the
four packages on sale, exactly one more Starter can be delivered. The catalogue
is ahead of the hardware.

The cost model in `ROADMAP.md` (€0.47–0.62 per sellable GB RAM) assumes the
reference machine: 2× Xeon, 256 GB, 8× 1.92 TB. On the current box those numbers
do not hold, because the fixed cost is spread over a fraction of the capacity.

### 1.3 A customer cannot reach their own VPS

This is the largest finding in this document, and it is an infrastructure fact
rather than a missing feature.

The network, as deployed:

| bridge | what | uplink |
|---|---|---|
| `vmbr0` | LAN, `192.168.1.0/24`, gateway `192.168.1.1` (the ISP router) | physical NIC |
| `vmbr1` | management, `192.168.10.0/24` — control plane, tunnel | none |
| `vmbr2` | **the customer VPS network**, `10.10.0.0/19` | **`bridge-ports none`** |

The Proxmox host carries exactly one address — `192.168.1.70/24`. There is no
public address anywhere on it, and it has no address on `vmbr2` at all.

The gateway for the customer network is not on the host: it is on the OpenWRT VM,
which straddles all three bridges. `eth2` holds `10.10.0.1/19`, the `vps`
firewall zone forwards to `wan`, and `wan` masquerades. So the outbound half of
the network genuinely works — a customer VPS reaches the internet, and the
control plane on the mgmt network reaches the VPS (there is a `mgmt -> vps`
forwarding), which is why the browser console works today.

The inbound half does not exist. There is no `wan -> vps` forwarding, no DNAT, no
public address. The only public ingress to the whole estate is the Cloudflare
tunnel, which serves the web app over HTTP — not raw SSH to a customer's machine.

Meanwhile `vpses.ip_address` holds `10.10.0.20`, `10.10.0.21`, and the dashboard
hands the customer that address as their SSH endpoint, port 22, user `root`. It
is unroutable from anywhere outside this one Proxmox host.

There is also no public-IP concept in the control plane — no allocation, no
floating IP, no port-forward, no DNAT — so even if the upstream router were
forwarding ports by hand, the platform would neither know about it nor be able
to hand a second customer a second port.

What this means: **the product as deployed cannot deliver what a VPS is.** No
SSH from outside, no website, no game server, nothing a buyer would assume. The
browser console is the only way in, and it runs through the control plane.

Note also what this makes true of a *second* node: the console works here only
because the control plane and the VPS network meet at one router. A node in
another building has no such shared router, so the console needs a path that does
not depend on the control plane being able to open a connection to the VPS —
see §3.8.

It also explains a hole in the cost model: `ROADMAP.md` budgets €0.75/month per
IPv4, and there are none.

This outranks everything else here, including the single-chassis problem in §1.1.
A machine that no customer can connect to does not become sellable by being made
redundant.

### 1.4 No backups

Still true, still the blocker for selling. A VPS disk lives on the node it runs
on; if the node dies, so does the data.

---

## 2. What already works, and should not be touched

Worth stating plainly, because the gap list below is long and could read as if
the foundation were weak. It isn't.

- **Placement is genuinely capacity-aware.** `Fleet.Scheduler.place/2` filters to
  online nodes in the requested region that fit, locks the candidate rows
  `FOR UPDATE` in a deterministic order (deadlock-safe), scores by headroom
  remaining after placement, decrements capacity and records a reservation — all
  in one transaction. Two concurrent placements cannot oversell a node.
- **Region filtering exists already.** The scheduler takes `region_id` and only
  considers nodes in it. The gap is that nothing lets the customer *choose*; see
  §3.1.
- **The agent dials out and is autonomous.** No inbound ports on nodes, and a
  control-plane outage does not stop VMs.
- **The overlay is management-only.** WireGuard is hub-and-spoke with the control
  plane as hub, used for the console and CP→node access. Customer traffic egresses
  via the node's own uplink. A hub outage costs consoles, not customer traffic —
  a distinction that would have been expensive to retrofit.
- **Nodes already carry their own network.** `vps_gateway`, `vps_cidr_prefix`,
  `vps_range_start`, `vps_range_end` are per-node, and `IpPool.allocate/1`
  receives the chosen node — placement happens first, addressing second. The
  ordering a second site needs is already right.

---

## 3. The gaps, in the order they should be closed

### 3.0 Get onto a second physical machine

Nothing else on this list is worth doing first. While the control plane, the
database, the router and the customer VPS share a chassis, resilience work is
decoration: any failure that the work would protect against takes the protected
thing with it.

The first split is also the cheapest one. Move the control plane and Postgres off
the box that carries customer workloads — a small external VM is €5–20/month.
That alone converts "everything dies together" into "the control plane and the
node fail independently", which is the premise the whole architecture already
assumes.

Only after that does a second *resource* node make the fleet meaningfully bigger.

### 3.1 Let the customer choose a region — **done**

The backend already placed per region; the frontend sent `region_code: "nl-1"` as
a literal. Closed by `GET /api/v1/regions` (only regions with an online node that
has capacity), a picker that appears when there is more than one answer, and
automatic placement when the customer expresses no preference — scored by the
same headroom measure the scheduler uses between nodes, so "automatic" means the
emptiest machine in the fleet. A region that is named but unknown stays an error;
only the absence of one means anywhere.

The original proposal, kept because the reasoning still holds:

- The customer picks a region, or picks "no preference".
- With no preference, the platform picks the region with the most free capacity,
  which is also what keeps the fleet balanced without any explicit balancing.
- A stated preference is a **constraint, not a hint**: if the chosen region is
  full, the request fails with a clear message rather than silently landing the
  VPS in another country. Data residency is a promise; quietly breaking it to
  satisfy an order is the wrong trade.

### 3.2 Public addressing — **done for shared IPv4**

The decision in §7 was Starter without its own IPv4, so what customers get is a
port on the node's address rather than an address of their own. That is now
built: `nodes.public_host` plus a forwarded port range, `port_forwards` allocated
per node in the same transaction as the private address, and an agent that makes
its firewall match a desired-state endpoint.

It cost nothing in address budget, which was the point — a dedicated IPv4 is
€2.27/month against a €3.99 plan.

Two things are deliberately still open:

- **Dedicated addresses**, for customers who need port 443 on an address of their
  own. The original shape here still holds when that day comes: a pool per node,
  allocated at provision, released on delete, and a region with capacity but no
  free address is full for the placement logic in §3.5.
- **A node with no public address at all** stays legitimate — the first one is
  that node. Those VPSes are console-only, and the UI says so rather than
  printing a private address as if it were an endpoint.

### 3.3 Backups — **done for the control plane, not for customer disks**

The control plane is backed up nightly: database plus `.env.prod`, encrypted to a
certificate whose private key is not on the machine, pushed to a destination that
accepts an append and nothing else. Restore verifies the dump against a recorded
checksum and refuses the live database name. One rehearsal has been run and its
numbers are in `docs/runbooks/backup-and-restore.md`.

Customer VPS disks are now backed up too, nightly, by the node that runs them:
`vzdump` in snapshot mode (the guest keeps running) to the node's own storage,
scheduled from the reconciler tick, two kept per VPS, and the archives listed
back to the customer as restore points.

That covers the failure customers actually have — they broke their own machine —
and not the one they would assume it covers: **the archives sit on the same node
as the VPS**, so a node losing its storage loses both. Moving them off-node, and
restoring to a *different* node, remains the cheapest failover story available at
this size and is the next step here.

Restoring is built: a button on the VPS page, a `:restore_backup` command, and a
`:restoring` status that blocks every other action on the machine while its disk
is being overwritten — including a second restore, which would race the first.
A failed restore leaves the VPS stopped rather than running, because after a
half-written `qmrestore` starting it automatically is the wrong default.

The rehearsal also ran on the machine the backup came from, which proves the
archive is restorable but not that recovery works with that machine gone.

### 3.4 The IP pool is not scoped to a network — **done**

`IpPool.used_ips/2` collected every VPS address in the system and filtered by
numeric range. That was correct only while every node used a distinct range — but
the *default* range was the same for every node, so the second node to enrol with
default settings would have shared the first one's pool and then collided on the
fleet-wide unique index.

Closed by `ControlPlane.Fleet.Subnets`: `10.10.0.0/16` is carved into 64 `/22`
blocks and enrolment hands each node the lowest free one, behind an advisory
lock. Allocation is scoped to the node, and the unique index is now
`(node_id, ip_address)` — the same address on two nodes is two different hosts,
not a conflict. A node that declares a complete network of its own still keeps
it; a half-declared one is rejected rather than silently overridden.

### 3.8 The console has no path to a remote node — **done**

The browser console SSHes from the control plane to `vpses.ip_address`. That
works today only because the control plane and the customer network meet at the
OpenWRT VM. A node in another building — which is the entire point of the second
node — has a private VPS subnet behind its own NAT, and the control plane has no
route to it and no public address of its own to be dialled back on.

The WireGuard overlay in the codebase does not solve this: keys and addresses are
handed out at enrolment, but nothing listens on UDP 51820 anywhere, and the
endpoint it would advertise (`app.bunkhosting.nl:51820`) points at Cloudflare,
which does not carry UDP.

The path that does work is the one the agent already uses: outbound HTTPS. On
request, the control plane sends the node's agent a short-lived connect token;
the agent dials back over WSS and relays bytes to the VPS's SSH port. It works
behind NAT, behind CGNAT and on a school network, needs no inbound port on the
node, and removes the overlay from the console's dependency list entirely.

Built as `ControlPlane.Console.Relay`. Every console goes this way, including on
the node the control plane can still reach directly — one path is testable, two
paths diverge and the rarely-used one breaks on the day it is needed. Verified
end to end against the live node: request queued, agent polled, dialled back,
opened SSH to the VPS, shell.

One thing to know before touching it: `:ssh.connect/3` accepts an already-
connected socket, which would be tidier than a loopback listener. That form does
not complete its negotiation on OTP 27 — not through a relay and not straight at
a VPS. The relay listens on loopback for that reason and no other.

Still open here: the overlay. It is now used by nothing. Either give it a real
endpoint and a hub that runs, or delete it — leaving enrolment handing out keys
for a network that does not exist is the worst of the three.

### 3.5 Scheduler: what to add, and what not to

Today's scoring — most headroom after placement — spreads load. For a small
fleet that is the right default: it leaves room for growth and limits how much a
single node failure takes down.

Worth adding, in this order:

1. **Node drain.** A node marked draining takes no new placements. Needed the
   first time hardware has to be patched, which is well before ten nodes. Cheap:
   one status value, one clause in `lock_candidates/2`.
2. **Per-owner anti-affinity.** A customer with several VPSes should not lose all
   of them to one failed node. Cheap as a tiebreak: prefer a node that carries
   none of that owner's VPSes.
3. **Region-level capacity for the "no preference" path** (§3.1).
4. **Explicit overcommit policy.** vCPU is safely oversubscribed; RAM in practice
   is not. Make the ratio configuration rather than an implicit property of how
   capacity is reported, so it can be tuned per node generation.

Deliberately **not** now: a pluggable scoring framework, bin-packing modes, live
migration. One node and three accounts do not justify them, and each would have
to be redesigned once there is real data about how the fleet is actually used.

### 3.6 Prepare for a second control plane without building one

The control-plane-HA research is unambiguous: the industry does not make the
control plane highly available, it makes it unimportant. Hetzner's own incident
notices say running servers are unaffected while the API is down for hours;
DigitalOcean's Droplet SLA does not mention the API at all; Fly.io moved *away*
from central consensus. Automatic Postgres failover needs three voting members
plus fencing, not one extra VM — at this size it lowers availability rather than
raising it.

So: do not build it. But four things are cheap now and are a rebuild later:

1. **Leader election around singleton work** (reconciler, metering tick, cron).
   One Postgres advisory lock behind a single abstraction. Today it always wins;
   the day a second instance starts, it is already correct.
2. **Idempotent, at-least-once commands.** Every command carries a key and
   tolerates redelivery. Moves the agent protocol towards desired-state
   reconciliation, where a lost or doubled message is self-healing instead of a
   wedged VPS.
3. **Expand/contract migrations.** Each migration backwards-compatible with the
   previous release — the precondition for ever running two versions at once.
4. **A console path that does not depend on the control plane.** Documented
   break-glass access, so a customer with a broken VPS during a CP outage is not
   locked out entirely.

### 3.7 Secrets and restore

`.env.prod` holds `SECRET_KEY_BASE` and the `CONSOLE_SSH` keypair.
Lose it and a database restore is not enough: without the console key there is no
way back into existing customer VPSes.

The backup I took during the tier migration currently sits on VM 102 — the same
VM as the control plane, so it is not a backup at all. It needs to be encrypted
and held off-machine, and the restore needs to have been rehearsed once with the
elapsed time written down. An untested restore is a hope, not an RTO.

---

## 4. What a second region actually requires

Collecting the above, adding a region is not a control-plane change. It is:

- a node in that location, with its **own uplink, gateway and unique private
  range** (already modelled per node — §2)
- **address space for that site** (§3.2), since customer-reachable addresses come
  from the local uplink
- a `regions` row, and the region exposed for selection (§3.1)
- the overlay reaching that node — works today, but every node's management
  traffic hairpins through the hub, which is worth revisiting once nodes are far
  apart
- a decision about **where that region's backups live** — same region keeps the
  residency promise simple, elsewhere survives losing the site

Notably absent: nothing in the scheduler, the billing, or the agent protocol has
to change to support a second region. That part is genuinely done.

---

## 5. Order of work

**First — make the VPS reachable.** Until a customer can connect to what they
bought, nothing else on this list changes whether the product can be sold. This
needs an uplink that carries public addresses: a colocated machine with routed
space, or a provider that hands out addresses per server. It is a hosting
decision before it is a code decision, and §6.1 is the fork.

**Then — stop sharing a chassis.** Control plane and Postgres onto their own
machine. Encrypted off-host copy of `.env.prod`. One rehearsed restore with a
measured time. In practice this probably falls out of the move above: the
machine that gets a real uplink is unlikely to be the one under a desk.

**Then — ship backups.** The remaining thing standing between this and taking a
paying customer seriously.

**Then — make the fleet real.** A second resource node on proper hardware and
node drain. (The per-network IP fix, region selection and the console path to a
remote node are done — see §3.4, §3.1 and §3.8.)

**Alongside, because it is cheap now and expensive later** — leader election,
idempotent commands, expand/contract migrations, the break-glass console path.

**Not yet** — Postgres replication, automatic failover, shared or replicated
storage, live migration, regional control planes. Each has a scale at which it
starts paying for itself, and the fleet is one to two orders of magnitude below
all of them.

---

## 6. Decisions needed before code

1. **Where does the public address space come from?** Researched and costed in
   §7; what remains is a budget ceiling and whether anything is already
   contracted.
2. **Where does the control plane move to?** Own hardware at a colo, or a small
   VM at another provider. The second is faster and cheaper; the first keeps
   everything under one roof.
3. **Which regions, and why?** A second Dutch site is a different product promise
   (redundancy) than a German or Nordic one (latency, residency). The answer
   shapes what to tell customers the choice is *for*.
4. **Backup target**: self-hosted object storage versus a provider. Trade-off is
   cost and control against one less thing to run.
5. **Still open from the pivot**: cheaper, or more managed? It has not moved, and
   it decides whether the effort after this goes into automation or into service.

---

## 7. Addressing and hosting: the options, costed

Researched 2026-09-12. Prices exclude VAT and move; treat as orders of magnitude,
not quotes.

### 7.1 What an IPv4 address actually costs

| | monthly | one-off |
|---|---|---|
| Hetzner, single additional IPv4 | €1.70 | €4.90 |
| Hetzner, /29 (6 usable) | €13.60 | €4.90 |
| Hetzner, /28 (14 usable) | €27.20 | €59.90 |
| Hetzner, IPv6 /56 per server | included | €15.00 |

A /29 works out at **€2.27 per usable address per month**.

`ROADMAP.md` budgets €0.75. The real figure is three times that, and it lands
hardest exactly where the margin is thinnest:

| package | price | IPv4 at €2.27 | share of revenue |
|---|---|---|---|
| Starter | €3.99 | €2.27 | **57%** |
| Basic | €7.99 | €2.27 | 28% |
| Pro | €14.99 | €2.27 | 15% |
| Business | €29.99 | €2.27 | 8% |

A dedicated IPv4 on the Starter tier eats more than half the revenue before a
single watt of power. That is a pricing problem, not a rounding error, and it has
three honest answers: drop the dedicated IPv4 from Starter (IPv6 plus shared
IPv4 ingress), raise the Starter price, or accept that Starter exists as a
loss-leader and say so internally rather than discovering it in the books.

Worth noting that the same arithmetic is why the low-cost end of the market sells
"NAT VPS" with a handful of forwarded ports. It is a real product category, not a
compromise — and it is also, roughly, what the current infrastructure already
does, minus the public ingress and minus any platform support for it.

### 7.2 Rent a machine, or rent rack space

**Dutch colocation**, per 1U:

| | price | power | traffic | IPv4 |
|---|---|---|---|---|
| PlanetNode (Freedom Internet DC, AMS-IX) | €45 | 0.5 A | 50 Mbit/s | 1 + /64 IPv6 |
| TransIP Professional | €47.19 | 0.5 A | 1000 Mbit/s | — |
| Eweka / AsHosting | €55 | — | 100 GB | — |

Add owned hardware at roughly €25/month amortised (the reference machine,
€1200 over four years) and a Dutch rack slot lands near €70/month.

Two things to notice. **The bandwidth varies by a factor of twenty** between
these — 50 Mbit/s, or 100 GB a month, is thin for a box meant to carry twenty
customer VPSes, and it is the sort of limit nobody notices until customers
complain. And **only PlanetNode publishes what IPv4 you get**; the others need a
quote, so the number that decides §7.1 is not on the page.

**A rented dedicated server** (Hetzner's auction, being the cheapest capable
option) removes the hardware purchase, the racking and the hardware-failure risk,
comes with no setup fee, unlimited traffic on a 1 Gbit/s port, and lets a /29 be
added for €13.60. The machine is in Germany or Finland.

### 7.3 Recommendation

**Start on a rented dedicated server with a /29, and move the control plane to a
separate small cloud VM at the same time.**

It resolves, in one step, the two findings that currently block everything: the
VPS network gets a real uplink with public addresses, and the control plane stops
sharing a chassis with customer workloads. It needs no capital, no rack visit and
no hardware gamble, and it can be cancelled monthly if the model does not work.
Six usable addresses is enough to prove the product with real customers; a /28 is
one support ticket away when it isn't.

Dutch colocation with owned hardware is the *better* end state — it is where the
€0.47 per sellable GB of RAM in the cost model actually applies, and where
"Nederlandse hosting" stops being a claim about a company and starts being a
claim about a location. It is the wrong *first* step: it wants capital and a
hardware commitment before there is evidence that anyone will buy.

Two things to check before committing:

- **Does the provider permit running a hosting business on the machine?** The
  Hetzner dedicated-server agreement I could read prohibits crypto mining, port
  scanning, MAC spoofing and forged source IPs — and says nothing either way
  about reselling or third-party customers. Absence of a prohibition is not
  permission. Ask them directly and get it in writing; a business built on an
  assumption here is one abuse report from being homeless.
- **The positioning cost.** The earlier recommendation was to compete on being
  Dutch, reachable and managed rather than on price. Running the machines in
  Germany does not destroy that — plenty of Dutch providers do exactly this — but
  it does mean the Dutch part of the story is about the company, not the
  hardware, and the website should not imply otherwise.
