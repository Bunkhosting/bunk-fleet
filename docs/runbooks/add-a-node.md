# Runbook — adding a resource node

Written for the second node in the fleet: someone else's machine, in someone
else's building, on someone else's internet connection. Everything here assumes
that, because the things that only work when the node is on your own LAN are
exactly the things that have bitten us.

The node never needs an inbound port. Enrolment, heartbeats, commands and the
browser console are all the agent dialling out over HTTPS.

---

## 1. What the operator needs before starting

- **Proxmox VE**, reachable at an address the agent can use.
- **An API token** for it: Datacenter → Permissions → API Tokens. The agent needs
  enough rights to clone, configure, start, stop and destroy VMs
  (`PVEVMAdmin` on `/` is the blunt version) **and `SDN.Use` on the bridge**.

  That second one is not optional and not included in `PVEVMAdmin`. Since Proxmox
  8.1 a plain Linux bridge lives under the SDN permission tree, so a token with
  every VM right there is still refuses to attach a NIC to `vmbr2`. Nothing says
  so until the first order: the node enrols, reports capacity, sits green, and
  then answers `clone template 9000: status 403: Permission check failed
  (/sdn/zones/localnetwork/vmbr2, SDN.Use)`. The installer offers to grant it; by
  hand it is:

  ```sh
  pveum acl modify /sdn/zones/localnetwork --roles PVESDNUser --tokens 'user@realm!tokenid'
  ```

  `PVESDNUser` ships with Proxmox and carries exactly `SDN.Audit` + `SDN.Use`.
  An earlier version of this runbook told you to create a role of your own,
  which did the same thing — but as a second role that exists separately on
  every node and can drift apart on an upgrade.
- **A cloud-init template** to clone. On a Proxmox host the installer builds one
  for you if the VMID the control plane provisions with does not exist yet: it
  pulls Ubuntu's own cloud image, verifies its published checksum, and turns it
  into a template. You are asked which storage it goes on and can say no. It is
  still a prerequisite everywhere else -- on ESXi the wizard imports an OVA, and
  when the agent runs on a helper VM instead of the host there is no `qm` to
  import with, so you build it by hand. Without a template the node enrols and
  heartbeats happily and every provision fails.
- **A bridge for customer traffic.** Node → Network → Create → Linux Bridge, no
  ports, no address. `vmbr2` by convention. It must exist before the install: the
  agent will address a bridge, never create one.

- **A forwarded port range**, if customers on this node should be reachable from
  the internet. Pick something well clear of anything the hypervisor uses —
  20000-29999 is the default — and forward it to the node on whatever router
  faces the internet. Without it the node still works; its VPSes are just
  console-only, which the dashboard says plainly rather than hiding.

Decide one thing up front: **who owns the gateway on that bridge.**

| situation | answer | `BUNK_MANAGE_NETWORK` |
|---|---|---|
| A plain bridge with nothing on it | Bunk builds the network | `1` |
| A router VM (OPNsense, OpenWrt, pfSense) already holds the gateway | the operator | `0` |

The first node in the fleet is the second case — the OpenWRT VM holds
`10.10.0.1`. If Bunk also claimed that address the network would go down, not up,
which is why the default is off and the installer asks.

---

## 2. Mint an enroll token

Tokens are single-use, time-limited, and bound to a region. Pick the region
first: a node in another city is only worth a separate region if you want
customers to be able to *choose* it, and an empty region is never shown to
anyone, so creating it early costs nothing.

```bash
# List regions
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://app.bunkhosting.nl/admin/v1/regions | jq

# Create one, if this node is somewhere new
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"code":"nl-2","name":"Nederland — <plaats>"}' \
  https://app.bunkhosting.nl/admin/v1/regions | jq

# Mint the token (valid one hour). region_code works as well as region_id.
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"region_code":"nl-2","ttl_seconds":3600}' \
  https://app.bunkhosting.nl/admin/v1/enroll-tokens | jq
```

The response carries the plaintext token — returned once — and an `install`
field: the exact command for §3, with the token already in it. Send it over
something that is not a group chat.

The dashboard does the same two things without curl: **Beheer → Locaties**
creates and renames regions and closes one that is being wound down (closed
means "nothing new lands here"; what runs there keeps running), and the node's
owner can move it to another location later from **Mijn nodes** — the VPSes on
it move with the machine. Only the owner can, because only the owner knows
where the hardware actually stands.

---

## 3. Install, on the Proxmox host itself

Paste the `install` line from §2, which is:

```bash
curl -fsSL https://app.bunkhosting.nl/install.sh | bash -s -- --token <TOKEN>
```

Run it **on the Proxmox host**, not on a helper VM, unless the operator is
managing the network themselves. Only from the host can the agent put the
gateway on the bridge and NAT customer traffic out of the node's own uplink.

The wizard first asks who will manage this node:

```
Beheerder van deze node:
  Alleen dit account kan straks de instellingen van deze node wijzigen
  in het dashboard. Gebruik het e-mailadres waarmee je op Bunk inlogt.
  E-mailadres: 
```

That address is the key to the node, not an administrative detail. Only that
account can change its settings afterwards, and only that account can hand the
node to someone else — an admin cannot, once a node has an owner. An admin can
assign an owner to a node that has none, which is what happens when the address
is left blank or names an account that does not exist yet. `--owner <email>`
answers it non-interactively.

The token wins over the typed address when it already carries an owner: whoever
holds a token should not be able to decide who owns the node by typing a
different address.

The wizard then asks for the API details, how much of the machine to offer, and
the network question from §1. It does not ask for an IP plan: the control plane
assigns the node a `/22` out of `10.10.0.0/16` and hands it back at enrolment.

On Proxmox it asks which VMIDs Bunk may use:

```
Nummers voor de VPS'en op deze node:
  Proxmox geeft standaard het laagste vrije nummer vanaf 100, dus klant-VPS'en
  komen tussen je eigen machines te staan. Geef een blok dat van Bunk is.
  Laagste VMID [2000]: 
  Hoogste VMID [2999]: 
```

Without a range the agent takes whatever `/cluster/nextid` returns, which is the
lowest free id on the cluster — so a customer VPS lands in the middle of your own
numbering. That is how the first node in this fleet ended up with a customer VPS
on 105, between the operator's 100 and 104. Pick a block that is yours to give
away; the wizard refuses a range containing the template id, because the agent
would eventually overwrite its own source.

On the Proxmox host it also asks about the template, but only when one is
missing:

```
Template voor nieuwe VPS'en:
  Er is nog geen template met VMID 9000 op deze node. Zonder
  template schrijft de node zich wel in, maar mislukt elke bestelling.
  Nu aanmaken uit Ubuntu's cloud-image? (J/n): 
  Opslag voor de template [local-lvm]: 
```

The storage has to exist; the installer checks with `pvesm status` before it
downloads anything and lists what is available if the name is wrong. Answering
no skips the step and leaves the node without a template, which is a legitimate
choice if you keep a golden image of your own -- give it VMID 9000.

The step is best-effort. If it fails the installer says why and carries on
installing the agent, and it removes the half-built VM rather than leaving a
broken 9000 behind for the next run to mistake for a finished template.

---

## 3b. Afterwards: settings live in the dashboard

Everything the wizard asked about capacity and numbering can be changed later
from **Mijn nodes** in the dashboard, by the owner and nobody else. A change is
picked up on the node's next heartbeat — within half a minute — and the agent
logs what it applied:

```
instellingen opgehaald uit het dashboard vmid_min=2000 vmid_max=2999 vcpu_per_core=3
```

What can be set there: how much of the machine goes to the pool, the VMID block,
how many vCPUs are handed out per physical core, and the pattern guests are named
by. An empty field means "leave it as the machine has it" — not zero.

The name pattern must contain `{id}`; the control plane refuses to save one that
does not. The agent recognises an already-created machine by its name, and a
pattern without a unique part lets one customer's VPS adopt another's. The other
placeholders are `{naam}`, `{klant}` and `{node}`.

The hypervisor credentials are not in the dashboard. They stay on the machine, in
the agent's service file.

---

## 4. Tell the control plane where the node can be reached

A node with no public address is legitimate — its VPSes are console-only. If this
one does have one, record it, and the port range its operator forwarded:

```sql
UPDATE nodes
   SET public_host = 'nl2.bunkhosting.nl',
       public_port_start = 20000,
       public_port_end   = 29999
 WHERE name = 'node-…';
```

From then on every VPS placed there is allocated an SSH port at provision time,
the agent installs the forwards on its next sync (within a minute), and the
customer's dashboard shows a real `ssh -p … user@host` line instead of "alleen
via de webterminal".

Existing VPSes on the node do not get a forward retroactively — allocation
happens at provision. Setting the address before ordering the first VPS there
saves that.

## 5. Check it actually worked

```bash
journalctl -u bunk-worker -f
```

Four lines, in order:

```
enrolled with control plane            node_id=...
control plane assigned the VPS network gateway=10.10.4.1 prefix=22 range=10.10.4.20-10.10.7.254
vps network ready                      bridge=vmbr2 subnet=10.10.4.0/22 uplink=<their uplink>
heartbeat sent                         avail_vcpu=... avail_ram_mb=... avail_disk_gb=...
```

`vps network ready` only appears when Bunk manages the network. With
`BUNK_MANAGE_NETWORK=0` you get "not managed" instead, and the operator owes you
a working gateway on the subnet the control plane assigned.

Then, from your side:

```bash
curl -s -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://app.bunkhosting.nl/admin/v1/nodes | jq '.nodes[] | {name, status, region, available_ram_mb}'
```

Order the smallest VPS in that region and open the console. That exercises the
whole chain — scheduler, address allocation, cloud-init, and the console relay
dialling back out of their network — and it is the only check that proves the
node can do the job rather than merely appear.

---

## 6. Taking a node back out

Closing a node is not the same as turning it off, and the difference matters
when someone's machine is running on it.

**Close it to new VPSes** — the operator UI's "Afsluiten" button, or:

```bash
curl -s -X POST -H "Authorization: Bearer $ADMIN_TOKEN" \
  https://app.bunkhosting.nl/admin/v1/nodes/<NODE_UUID>/drain | jq
```

The scheduler stops placing there. Everything already on the node keeps running,
keeps being metered, keeps its console. The node keeps heartbeating, and its
heartbeat no longer flips it back open.

**Then empty it**, deliberately: there is no automatic migration, because moving
someone's VPS is not something to trigger by changing a status field. Today that
means telling those customers, or rebuilding their VPS elsewhere.

**Then remove it.** `DELETE /admin/v1/nodes/:id` refuses while the node still
hosts a live VPS, which is the backstop for having skipped the previous step.

An offline node can be drained but not resumed. Draining one that is already
down is how you stop it re-entering rotation the moment it recovers; whether it
is alive again is the reconciler's call, from evidence, not something to assert
by hand.

## 7. When something is wrong

**Node never appears.** The token is single-use: if the install was run twice,
the second run consumed nothing and the agent has no credentials. Mint another.

**Node online, every provision fails.** Almost always the template. On ESXi,
check that `BUNK_ESXI_TEMPLATE` names a VM that exists. On Proxmox, run
`qm config 9000` on the host: no such VM means the installer's template step was
skipped or failed, and `journalctl -u bunk-worker` will show the clone failing on
that id. Re-run the installer to have it built, or build it by hand.

A template that exists but produces unusable VPSes is nearly always missing one
of two things the agent depends on: the disk must be `scsi0`, because that is
what gets resized to the ordered size, and there must be a cloud-init drive, or
the address, user and SSH keys are configured into nothing.

**Node is online but offers nothing.** The panel says how much is free; when the
node reports less than the scheduler thinks it has, it says so there too, and the
lower of the two is what counts. A node offering zero vCPU on a busy host used to
be normal and is not any more: available vCPU is `cores × BUNK_VCPU_OVERSUBSCRIBE
− assigned`, default factor 3. RAM is never oversubscribed, so a node with no
free RAM genuinely has none.

**Node shows a warning that the agent cannot reach the hypervisor.** That is an
agent which is alive and heartbeating, but whose Proxmox or ESXi API is not
answering — wrong address or port, a token without the rights it needs, or a
firewall in between. The message in the panel is the agent's own error. Nothing
new is placed on that node until it clears, which it does by itself on the first
heartbeat that can measure again. Before this existed such a node simply went
offline, which looked exactly like a machine that was switched off.

**Nobody can change a node's settings.** Check who owns it — the dashboard shows
it on the node card in the admin panel. Only the owner can change settings, and
only the owner can hand the node over; an admin can do neither once a node has an
owner. That is deliberate, and it has a sharp edge: if an owner becomes
unreachable, nobody can transfer that node. An admin can only assign an owner to
a node that has none.

**VPS gets an address but no connectivity.** Ask who owns the gateway. With
`BUNK_MANAGE_NETWORK=1`, `ip addr show vmbr2` on the node should carry the
assigned `.1`, `sysctl net.ipv4.ip_forward` should be 1, and
`iptables -t nat -S POSTROUTING` should have a MASQUERADE line naming the node's
subnet. With `0`, that is all the operator's to check.

**Console spins and gives up.** The agent's log says whether it ever saw the
request (`console session open`) and whether it could reach the VPS. If the
request never arrives, the agent is not polling — check the control-plane URL and
that the node is still authenticated. If it arrives and the VPS is unreachable,
the VPS is on a subnet the node itself cannot route to, which is the same
gateway question again.

**Addresses run out on one node and not another.** They cannot any more — each
node has its own `/22` and allocation is scoped to the node — but if it looks
that way, check `nodes.vps_range_start`: a node that declared its own network at
enrolment kept it, and a narrow declared range is a narrow pool.
