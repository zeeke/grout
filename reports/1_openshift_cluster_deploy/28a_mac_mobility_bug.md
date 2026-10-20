# Prompt: grout EVPN IP mobility reproducer (kernel baseline vs grout)

Paste everything below the line into a new Claude Code session started in the
`DPDK/grout` repository (`~/dev/github.com/DPDK/grout`).

---

## Goal

Write a reproducer that shows an **EVPN IP-mobility bug in grout**: when an IPv4
address moves from a host behind one VTEP to a host behind another VTEP (a VIP
failover with keepalived), the **Linux kernel + FRR** datapath converges on the
new location, but **grout + FRR (`dplane_grout`)** keeps the stale binding forever.

Deliverables:

1. **Kernel baseline.** A standalone script (e.g. `smoke/manual/evpn_ip_move_kernel.sh`,
   or a temporary path outside the repo, your choice) that uses only network
   namespaces, Linux bridges/VXLAN and FRR, with two VTEPs. It must show that the
   IP move is handled correctly, with command → output evidence at each step.
2. **grout reproducer.** A smoke test modelled on the existing ones, e.g.
   `smoke/evpn_ip_mobility_frr_test.sh`, with one Linux+FRR VTEP and one
   grout+FRR VTEP. It runs the same scenario in both directions and **fails on
   current `main`** at the exact assertion that corresponds to the bug.
3. **A short write-up** (in your final message) containing: what the kernel does, what
   grout does, the code paths responsible, and a suggested fix direction. Keep the
   evidence (commands + output); do not claim anything you did not observe.

**Important:** "the kernel handles it" is a **hypothesis**, not a fact. Verify it
first. If the kernel baseline also fails (for example because FRR installs remote
neighbours as `NUD_NOARP` + `NTF_EXT_LEARNED` and `arp_process()` refuses to
override them without `NEIGH_UPDATE_F_ADMIN`), stop and report that with
evidence before writing the grout test. Find out exactly which mechanism (kernel
neigh update, FDB move, zebra `zebra_evpn_neigh` local-learn of a previously
remote neigh, MAC-mobility sequence numbers) makes it converge, because the grout
fix has to reproduce that mechanism.

Do not modify grout sources in this session unless I ask; the task is the
reproducer and the analysis.

## Where this comes from (production evidence)

OpenShift cluster deployed with OpenPERouter, using grout 0.18.0 as dataplane and
FRR 10.7.x with the `dplane_grout` zebra module. L2VNI 210 (`br-pe-210`, VRF `red`,
anycast gateway `192.168.110.1/24` and `fd00:110::1/64` on the bridge SVI) carries
the node network `192.168.110.0/24`. Each node's host NIC is attached to the
bridge through a grout port (`t_9nnsgw.42`). The VTEPs are `fd00::2` (master-0),
`fd00::3` (master-1) and `fd00::4`/`::5`/`::6`, and there is an iBGP EVPN full mesh
(route reflector).

The API VIP `192.168.110.10` was first held by keepalived on **master-0** during
bootstrap, then moved to **master-1**. master-1's keepalived now sends gratuitous
ARPs every ~60 s (`Sending gratuitous ARP on br-ex for 192.168.110.10`). The IPv6
VIP `fd00:110::10` moved correctly. The IPv4 VIP did not:

```
# master-0 FRR still originates the VIP with its own MAC
*>  [2]:[0]:[48]:[52:54:00:e4:1d:d3]:[32]:[192.168.110.10] RD 10.0.0.2:3
                    fd00::2                            32768 i
# master-0 EVPN ARP cache
192.168.110.10   local   active   52:54:00:e4:1d:d3
fd00:110::10     remote  active   52:54:00:a4:5a:c9 fd00::3    <- IPv6 VIP is fine
# master-1 EVPN ARP cache (the real VIP owner)
192.168.110.10   remote  active   52:54:00:e4:1d:d3 fd00::2    <- never becomes local

# grout nexthops
master-0: red  learn       br-pe-210 L3 family=ipv4 addr=192.168.110.10 state=reachable mac=52:54:00:e4:1d:d3 flags=neigh
master-1: red  7  zebra    br-pe-210 L3 family=ipv4 addr=192.168.110.10 state=reachable mac=52:54:00:e4:1d:d3 flags=remote neigh

# master-0 host no longer owns the VIP
$ ip -4 a | grep -c 192.168.110.10
0
# from master-2: ARP for the VIP is answered with master-0's MAC, so traffic is blackholed
$ arping -c 3 -I br-ex 192.168.110.10
Unicast reply from 192.168.110.10 [52:54:00:E4:1D:D3]  1.907ms
```

grout interface config on the nodes:
```
br-pe-210: type bridge, mode VRF, vrf red, bridge_flags: flood learn neigh_suppress   (no neigh_snoop)
vni210:    type vxlan, domain br-pe-210, vni 210, local fd00::3, no "learning" vxlan flag (FRR plugin turns it off)
nexthop config: lifetime 1200, unreachable 60, ucast_probes 3, bcast_probes 3
```

The OpenPERouter kernel-dataplane equivalent (for the baseline) is: Linux bridge
`br-pe-<vni>` with the SVI IP (anycast GW) in VRF `red`, and a VXLAN port with
`learning off` and `neigh_suppress on` (see openperouter
`internal/hostnetwork/vxlan.go` and `link_properties.go:setNeighSuppression`). In
FRR there is `advertise-all-vni` under `address-family l2vpn evpn`.

## Suspected root causes in grout (verify them)

There are two independent defects:

**A. The destination VTEP ignores the new owner's GARP when the IP is held as a
remote EVPN neighbour.**
- v0.18.0: `modules/ip/datapath/arp_input_request.c` drops every gratuitous ARP
  (target IP is not local), so it never reaches `arp_probe_input_cb`.
- v0.19.0+ (PR #759, commits `99b5cab9`, `5bc22e95`, `d414322b`, `d27570a6`;
  issue #757): a GARP is accepted only if `GR_IFACE_F_NEIGH_SNOOP` is set, or if
  the sender IP is already a `GR_NH_F_NEIGH` nexthop on the same iface. Then
  `modules/ip/control/nexthop.c:arp_probe_input_cb` refuses to touch the
  existing nexthop when it has `GR_NH_F_REMOTE` (or `GR_NH_F_LOCAL`), by design
  ("Never overwrite a local address, a remote (EVPN) nexthop..."). The new
  smoke test `smoke/arp_ndp_test.sh` even asserts that the IP must not move
  (`fail "192.168.0.2 moved away from p0"`), but it has no EVPN.
- Result: master-1 never creates a local learned entry, zebra never sees a local
  neigh, no type-2 route with a higher MAC-mobility sequence is advertised, and
  master-0's route keeps winning.
- Check the IPv6/NDP side too (`modules/ip6/datapath/ndp_na_input.c`,
  `modules/ip6/control/nexthop.c`). In production the IPv6 VIP *did* move, so
  find out why the NDP path behaves differently (ordering? the IPv6 VIP was never
  learned on master-0? different gating?). That difference is a useful hint.

**B. The origin VTEP keeps the stale learned entry alive.**
- On master-0 the `learn` nexthop for `.10` stayed `state=reachable` for >2 h,
  although `lifetime 1200`, and the host no longer answers ARP for `.10`.
  Find what refreshes it: the aging/probe path in `modules/infra/control/nexthop.c`
  and the `arp_probe_input_cb` refresh branch. Could flooded ARP traffic with
  `sip=.10` refresh it, could the probe never fire for `learn` nexthops, or
  could the `neigh_suppress` proxy reply loop back? If master-0 had aged it
  out, zebra would withdraw the route and the move would eventually converge
  even with defect A.

Releases v0.19.1/v0.19.2 only contain mempool/mbuf/diag changes and do not touch this.

## Reproducer design

Reuse the smoke infrastructure: `smoke/_init.sh`, `smoke/_init_frr.sh`,
`start_frr <netns> <id>`, `create_interface`, `move_to_netns`, `netns_add`,
`mark_events`/`wait_event`, `fail`. Start from
`smoke/evpn_neigh_suppress_frr_test.sh` (SVI IP on both bridges,
`neigh_suppress` on, `neigh_snoop` on the grout bridge) and
`smoke/evpn_vxlan_frr_test.sh`. Note the existing zebra workaround for
FRRouting/frr#21190 (wait for `L2 VNIs` before creating the VXLAN iface). Read
how smoke tests are run (meson/`make smoke-tests` or similar) and run them the
same way.

Topology (IPv4 overlay is enough for the bug; add IPv6 as a second phase if cheap):

```
 host-a (10.0.0.2, VIP 10.0.0.10 initially)         host-b (10.0.0.3)
        |                                                   |
   [Linux VTEP: evpn-peer]  <-- iBGP EVPN, VNI 100 -->  [grout VTEP]
   br100 SVI 10.0.0.1/24 (anycast GW)                   br100 SVI 10.0.0.1/24
   vxlan100 learning off, neigh_suppress on             neigh_suppress on (+/- neigh_snoop)
```

Scenario, run in **both directions**: Linux→grout (exercises defect A on grout)
and grout→Linux (exercises defect B on grout):

1. Bring up EVPN, then ping between host-a and host-b so the type-2/3 routes are established.
2. Add VIP `10.0.0.10/32` on the "old" host and send a GARP (`arping -U -c3 -I x-p1 10.0.0.10`,
   or `-A`). Assert both VTEPs have the type-2 MAC+IP for `.10` → old host MAC
   (`vtysh -c "show evpn arp-cache vni 100"`, `show bgp l2vpn evpn route type macip`,
   `grcli nexthop show`, `ip -n evpn-peer neigh show dev br100`).
3. Move the VIP: delete it from the old host and add it on the "new" host, which sends
   GARPs the way keepalived does (several, e.g. every second for 5 s; also test a single one).
4. Assert, with a bounded wait (for example 30 s, well below the 1200 s lifetime),
   that:
   - the new VTEP has `.10` as **local** with the new MAC, and it is advertised as a
     type-2 route with an incremented MAC-mobility seq (`show evpn arp-cache vni 100 ip 10.0.0.10`);
   - the old VTEP withdraws its local route and installs the remote one;
   - a third observer (for example the other host) resolves `.10` to the **new** MAC
     (`arping -c1 10.0.0.10` / `ip neigh`) and `ping 10.0.0.10` succeeds.
5. Also cover the keepalived-like timing where the old host's entry is not
   cleaned explicitly: no ARP for `.10` from the old host after the move.
   Observe whether the old VTEP's entry ages out within `lifetime`. Use
   `grcli nexthop config set lifetime <small>` if available, to keep the test fast.

Run the identical scenario first on the **kernel-only** topology (two Linux+FRR
VTEP netns) to establish the baseline, then on the mixed topology. If needed,
check that both FRR instances (Linux peer and grout's) run the same FRR version
as the one used by `_init_frr.sh`.

## Constraints and style

- Match the existing smoke test style: bash, SPDX header, ASCII topology diagram in
  the header comment, `attempts` loops with explicit `fail` messages, and dump
  `grcli`/`vtysh`/`bridge` state on failure.
- Give evidence for every claim (command → output). When the grout test fails, show
  the exact assertion and the state dumps proving defect A and/or B.
- Do not commit or push. Leave the files in the working tree and summarise what I need
  to run (`sudo`, needed packages, the exact command line).
