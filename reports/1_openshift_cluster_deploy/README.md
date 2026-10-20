# Deploy 33: install stuck because the API VIP points to the wrong node

Data collected 2026-10-20, 14:02–14:05 UTC. Every time in this report is UTC.

## TL;DR

The OpenShift install is stuck. The cluster API is published on a floating IP
address, the **API VIP `192.168.110.10`**. That address moved from master-0 to
master-2, but the network fabric (grout + FRR EVPN) still delivers its traffic
to **master-0**, which no longer owns it. All traffic to the VIP is dropped,
so the bootstrap node can't reach the API and the install can't finish.

The API itself is healthy. Contacted directly at master-2's own IP
(`192.168.110.4`), it answers `200`. Only the VIP path is broken.

This is the same bug that was seen in deploys 28 and 29
(`./28a_mac_mobility_bug.md`, `./29_csr_and_vip_monilty_issue.md`). It still
happens with **grout 0.19.3** and **FRR 10.7.1**.

---

## 1. Background (no networking expertise assumed)

### 1.1 IP address vs MAC address, and ARP

- An **IP address** (e.g. `192.168.110.10`) is the logical address you connect to.
- A **MAC address** (e.g. `52:54:00:00:50:29`) is the hardware address of one
  specific network card. Frames on the wire are delivered by MAC.
- **ARP** is how a machine finds which MAC owns an IP. It broadcasts "who has
  192.168.110.10?", and the owner replies "I do, my MAC is X". The answer is
  cached.
- A **gratuitous ARP (GARP)** is an unsolicited announcement: "192.168.110.10
  is now at MAC X, update your caches". It is sent when an address moves.

### 1.2 The VIP and keepalived

The OpenShift API is reached at a **virtual IP** (VIP), `192.168.110.10`
(`api-int.sno-lab.example.com`). It belongs to no fixed machine. A daemon
called **keepalived** runs on the masters. They elect one owner, which adds the
VIP to its network interface and sends GARPs. When ownership changes, the old
owner removes the VIP and the new one adds it and sends GARPs.

During installation the VIP **moves on purpose**. The bootstrap node (master-0)
holds it at first. When the real control plane is up on the other masters, one
of them takes it over.

### 1.3 The overlay network: EVPN, VTEPs, grout

The nodes are not on a plain shared switch. Each node runs a small software
router:

- **grout** is the fast packet-forwarding engine (the "dataplane").
- **FRR** is the routing control software. It talks BGP with the other nodes.

Together they emulate one big virtual switch, the **L2 VNI 210** segment
`192.168.110.0/24`, over the physical network. This technique is called
**EVPN/VXLAN**. Each node's router is a **VTEP** (tunnel endpoint), identified
by an address like `fd00::2`.

How the "virtual switch" knows where everyone is:

1. When grout sees a local host use an IP/MAC, it **learns** it as *local*.
2. FRR then advertises it to all other nodes over BGP in an **EVPN type-2
   route**: "IP 192.168.110.10 with MAC 52:54:00:00:50:29 is behind VTEP
   fd00::2".
3. The other nodes install that as a *remote* entry and tunnel the traffic to
   that VTEP.
4. **ARP suppression** (`neigh_suppress`): when a host asks "who has
   192.168.110.10?", its local grout **answers on the owner's behalf** from
   that table and doesn't flood the question. Hosts therefore believe whatever
   the EVPN table says.

When an IP moves to a different node, the expected sequence is: the new node's
grout sees the GARP and learns the IP as local. FRR advertises a new type-2
route with a higher "mobility sequence number". The old node sees it, drops its
own entry, and everyone converges on the new location.

```
            BGP EVPN (control plane: "who is where")
   ┌────────────────────────┬────────────────────────┐
   │                        │                        │
 master-0 (VTEP fd00::2)  master-2 (VTEP fd00::4)  worker-0, master-1, worker-1 ...
 grout+FRR                grout+FRR                grout+FRR
   │ enp8s0                 │ br-ex                  │
 host .2                  host .4 + VIP .10        host .5 / .3 / .6
 MAC 52:54:00:00:50:29    MAC 52:54:00:a4:3e:78
```

---

## 2. What went wrong, in one picture

```
 Reality (keepalived):   VIP 192.168.110.10 is on master-2 (MAC 52:54:00:a4:3e:78)
 Fabric (EVPN tables):   VIP 192.168.110.10 is on master-0 (MAC 52:54:00:00:50:29)  <- stale

 worker-0 ── "who has .10?" ──> local grout answers "52:54:00:00:50:29" (master-0)
          ── packets ─────────> tunneled to master-0 ──> master-0 doesn't own .10 ──> dropped
```

The move has two halves, and **both** fail:

- **A. The new owner never claims the IP.** master-2 has sent 41 GARPs for
  `.10` since 13:34:29. Its grout still lists `.10` as a *remote* entry
  pointing at master-0, and FRR never advertises a new route.
- **B. The old owner never forgets the IP.** master-0 released the VIP at
  13:14:00. 50 minutes later its grout still lists `.10` as a *local, reachable*
  entry, even though the configured entry lifetime is 30 s. FRR keeps
  advertising it.

Either half alone would be survivable. If A worked, master-2 would advertise a
newer route and win. If B worked, the stale route would be withdrawn and
master-2's GARPs would then be learned normally. Because both fail, the stale
state never goes away.

**The IPv6 VIP `fd00:110::10` moved correctly** to master-2 (section 4.3).
This points at the IPv4/ARP handling in grout specifically, not at keepalived
or BGP.

---

## 3. Timeline

| Time (UTC) | Event | Source |
|---|---|---|
| 12:50 | Images regenerated, VMs booted | file mtimes on server |
| 12:59:49 | master-0 keepalived becomes MASTER and adds the VIP. GARP sent on `enp8s0`. grout learns `.10` → `52:54:00:00:50:29` as local | `data/master-0.keepalived.txt`; arp-cache uptime 01:02:56 at 14:02 |
| 13:14:00 | master-0 keepalived: `sent 0 priority`, `removing VIPs`. The VIP leaves master-0 | `data/master-0.keepalived.txt` |
| 13:14 → 13:34 | No node holds the VIP | keepalived logs |
| 13:29:52 | master-2 keepalived starts (BACKUP) | `data/master-2.keepalived.txt` |
| 13:34:29 | master-2 becomes MASTER, adds the VIP to `br-ex`, starts sending GARPs | `data/master-2.keepalived.txt` |
| 13:34 → now | Every GARP is ignored by the fabric. `wait-for-ceo` on master-0 fails with `no route to host` | `data/master-0.installer.txt` |
| 14:05:29 | Last observed GARP from master-2 (41 in total) | `data/master-2.keepalived.txt` |

---

## 4. Evidence

Raw output for every command is in `data/<node>.<topic>.txt`.
`collect.sh` regenerates it.

### 4.1 The VIP is really on master-2, not on master-0

```
# master-0 (data/master-0.host.txt)
$ ip -4 addr | grep -c 192.168.110.10
0

# master-2 (data/master-2.host.txt)
br-ex  UNKNOWN  192.168.110.4/24 169.254.0.2/17 192.168.110.10/32 fd00:110::10/128 ...

# master-2 keepalived (data/master-2.keepalived.txt)
13:34:29 (sno-lab_API_0) Entering MASTER STATE
13:34:29 Sending gratuitous ARP on br-ex for 192.168.110.10
...      (41 GARPs in total, last at 14:05:29)
```

### 4.2 The VIP is unreachable from every node except its owner; the API behind it is fine

From `data/*.reach.txt`:

| From | `ping 192.168.110.10` | `curl https://192.168.110.10:6443/readyz` | `curl https://192.168.110.4:6443/readyz` (master-2 direct) |
|---|---|---|---|
| master-0 | 100% loss | 000 (no connection) | 200 |
| master-1 | 100% loss | 000 | 200 |
| master-2 | ok (local) | 200 | 200 |
| worker-0 | 100% loss | 000 | 200 |
| worker-1 | 100% loss | 000 | 200 |

Pinging the nodes' own IPs `.2`, `.3`, `.4` works from every node, so the
overlay itself is up. Only the moved IP is broken.

### 4.3 Every EVPN table says ".10 is master-0"

FRR's view (`show evpn arp-cache vni all`, `data/*.evpn.txt`):

```
master-0: 192.168.110.10  local   active  52:54:00:00:50:29                <- claims to own it
master-2: 192.168.110.10  remote  active  52:54:00:00:50:29  fd00::2       <- the real owner thinks it's elsewhere
worker-0: 192.168.110.10  remote  active  52:54:00:00:50:29  fd00::2

# IPv6 VIP, for comparison: moved correctly
master-0: fd00:110::10    remote  active  52:54:00:a4:3e:78  fd00::4
master-2: fd00:110::10    local   active  52:54:00:a4:3e:78
```

Detail on master-0 and master-2. Both mobility sequence numbers are 0, so no
move was ever signalled:

```
master-0$ show evpn arp-cache vni 210 ip 192.168.110.10
 Type: local   State: active   Uptime: 01:02:56   MAC: 52:54:00:00:50:29   Local Seq: 0 Remote Seq: 0
master-2$ show evpn arp-cache vni 210 ip 192.168.110.10
 Type: remote  State: active   Uptime: 00:35:56   MAC: 52:54:00:00:50:29   Remote VTEP: fd00::2   Local Seq: 0 Remote Seq: 0
```

The only BGP route for the VIP is master-0's (RD `10.0.0.2:3`). master-2 never
originated one:

```
*>  [2]:[0]:[48]:[52:54:00:00:50:29]:[32]:[192.168.110.10] RD 10.0.0.2:3   fd00::2   32768 i
```

### 4.4 grout's forwarding table agrees, and master-0's entry doesn't expire

`grcli nexthop show` (`data/*.grout.txt`):

```
master-0: red  learn  br-pe-210 L3 addr=192.168.110.10 state=reachable mac=52:54:00:00:50:29 flags=neigh
master-1: red  zebra  br-pe-210 L3 addr=192.168.110.10 state=reachable mac=52:54:00:00:50:29 flags=remote neigh
master-2: red  zebra  br-pe-210 L3 addr=192.168.110.10 state=reachable mac=52:54:00:00:50:29 flags=remote neigh
worker-0: red  zebra  br-pe-210 L3 addr=192.168.110.10 state=reachable mac=52:54:00:00:50:29 flags=remote neigh
worker-1: red  zebra  br-pe-210 L3 addr=192.168.110.10 state=reachable mac=52:54:00:00:50:29 flags=remote neigh
```

- `learn` = grout learned it from local traffic. `zebra` + `remote` = installed
  by FRR from a BGP route.
- grout config on all nodes: `lifetime: 30`. master-0's `learn` entry is still
  `reachable` 50 minutes after the host dropped the IP (defect B).
- Bridge flags: `br-pe-210 ... bridge  flood learn neigh_suppress`. ARP
  suppression is on and `neigh_snoop` is **off**.

### 4.5 Hosts are told the wrong MAC (ARP suppression answering from the stale table)

```
master-1$ arping -c3 -I br-ex 192.168.110.10
Unicast reply from 192.168.110.10 [52:54:00:00:50:29]   <- master-0's MAC, not master-2's 52:54:00:a4:3e:78
worker-0$ arping -c3 -I enp8s0 192.168.110.10
Unicast reply from 192.168.110.10 [52:54:00:00:50:29]
```

master-0 itself doesn't own the address any more. Its own kernel can't resolve
it, so the request fails locally (`192.168.110.10 dev enp8s0 FAILED`,
`data/master-0.host.txt`).

### 4.6 Effect on the install

```
# master-0 wait-for-ceo (data/master-0.installer.txt), repeating since 13:34
waitforceo.go:69] waiting on condition EtcdRunningInCluster in etcd CR /cluster to be True.
"Failed to watch" err="... Get \"https://api-int.sno-lab.example.com:6443/...\": dial tcp 192.168.110.10:6443: connect: no route to host"

# assisted-installer: all other hosts stuck
master-1 Writing image to disk / master-2 Writing image to disk / worker-0 ... / worker-1 ...
```

In deploy 29, the same situation made assisted-service mark every host `error`
after about 75 minutes. CSR approval then stopped, and the cluster ended up with
only 2 of 5 nodes.

### 4.7 Versions

```
grcli 0.19.3-1.el10fdp
FRRouting 10.7.1 (routerpod)
```

---

## 5. What we know vs. what is still a hypothesis

**Observed (evidence above):**
- The VIP moved in keepalived: master-0 released it at 13:14:00 and master-2
  took it at 13:34:29.
- The EVPN control plane and the grout dataplane never followed the IPv4 move.
  The IPv6 VIP did follow.
- master-0's grout `learn` entry for `.10` stays `reachable` well beyond the
  30 s lifetime.
- The new owner's GARPs produce no local entry and no new route.

**Hypotheses (from the deploy 28 analysis, `./28a_mac_mobility_bug.md`; not
re-verified against grout 0.19.3 sources here):**
- *Defect A:* grout accepts a GARP only when `neigh_snoop` is enabled on the
  bridge, or when the sender IP is already a neighbour on that interface. Even
  then, `arp_probe_input_cb` deliberately refuses to overwrite a nexthop flagged
  `remote` (EVPN). `neigh_snoop` is off here, and `.10` is `remote` on master-2,
  so the GARP is discarded.
- *Defect B:* something keeps refreshing master-0's `learn` entry, or the aging
  probe never fires for it. Not yet identified.
- Why IPv6 works is not yet explained. The NDP code path likely gates
  differently, which is a useful hint for the fix.

---

## 6. How to get this install unblocked (workaround, not a fix)

Not done yet. The idea is to remove the stale *local* entry on master-0 so FRR
withdraws its route. Then, on the next GARP from master-2 (or by enabling
`neigh_snoop`), master-2 learns `.10` locally and advertises it. Options to
try, least invasive first:

1. On master-0, delete grout's learned nexthop for `192.168.110.10` in VRF
   `red` (`grcli nexthop del ...`), then watch `show evpn arp-cache vni 210 ip
   192.168.110.10` on master-2 turn `local`.
2. Enable `neigh_snoop` on `br-pe-210` on all nodes, so GARPs are processed
   (targets defect A).
3. As a last resort, restart grout+FRR on master-0. This disturbs master-0's
   own connectivity during bootstrap.

Check after any step: `curl -sk https://192.168.110.10:6443/readyz` from
worker-0 should return `200`.

---

## 8. Update 14:30 UTC: the VIP converged once master-0 went away

`collect.sh` gained `grcli nexthop show internal`, `grcli fdb show` and
`grcli mac show`. It was re-run into `data-1430/`. The 14:02 snapshot in
`data/` was left untouched; it does not contain these three commands.

Between the two snapshots, **master-0 stopped answering SSH**. Its VM is still
running and it answers ping on the management network, so it is most likely
rebooting:

```
$ ./remote-cmd.sh master-0 ...
ssh: connect to host 192.168.150.20 port 22: Connection refused
$ virsh domstate openpe-master-0 --reason      -> running (booted)
$ ping -c1 192.168.150.20                       -> 1 received
```

With master-0 gone, the stale entry disappeared and the fabric moved the IPv4
VIP to master-2:

```
# master-2: now local, learned about 14:28:10 (uptime 00:03:38 at 14:31:48)
IP: 192.168.110.10  Type: local  MAC: 52:54:00:a4:3e:78  Local Seq: 0 Remote Seq: 0
*>  [2]:[0]:[48]:[52:54:00:a4:3e:78]:[32]:[192.168.110.10] RD 10.0.0.4:3   fd00::4   32768 i

# grout, master-2 (owner) vs worker-0 (peer)
master-2: red  learn  br-pe-210 L3 addr=192.168.110.10 state=reachable mac=52:54:00:a4:3e:78 flags=neigh
worker-0: red  zebra  br-pe-210 L3 addr=192.168.110.10 state=reachable mac=52:54:00:a4:3e:78 flags=remote neigh

# grout bridge table (fdb): master-2's MAC is local on master-2, behind VTEP fd00::4 elsewhere
master-2: br-pe-210  52:54:00:a4:3e:78   t_enp7s0.42           learn    0
worker-0: br-pe-210  52:54:00:a4:3e:78   vni210       fd00::4  extern  18

# ARP and API through the VIP now work
$ arping -c3 -I br-ex 192.168.110.10   (master-1)
Unicast reply from 192.168.110.10 [52:54:00:A4:3E:78]
VIP 192.168.110.10:6443/readyz -> 200   (master-1, master-2, worker-0, worker-1)
```

This supports the analysis in section 2. The move works as soon as the old
owner's stale entry is gone. Nothing else was changed in between: no manual
intervention was made on the cluster.

The install is **not** healthy yet (from the hypervisor, 14:34):

```
$ oc get nodes
master-1   Ready   control-plane,master   80m
master-2   Ready   control-plane,master   79m
$ oc get clusterversion
version   False   True   93m   Unable to apply 4.22.3: an unknown error has occurred: MultipleErrors
$ oc -n kube-system get cm bootstrap
Error from server (NotFound): configmaps "bootstrap" not found
event (about 14:29): etcd Available=False "0 of 3 members are available, master-2 is unhealthy, etcd-bootstrap is unhealthy, master-1 is unhealthy"
```

**Still unknown:**
- Why and exactly when master-0 went down. Bootstrap had not completed:
  there's no `bootstrap` configmap, and etcd still lists `etcd-bootstrap`.
- Whether master-0's BGP session dropped before 14:28:10. That would confirm
  that the stale route was withdrawn because master-0 disappeared, rather than
  by aging.
