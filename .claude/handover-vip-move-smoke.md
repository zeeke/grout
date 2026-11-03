## Goal

Write a minimal smoke test that reproduces the OpenPERouter e2e test "moves the
VIP when the new owner claims it right after the old owner releases it". The
test must fail on grout without the fix in
`modules/l2/datapath/bridge_neigh_suppress.c` and pass with it.

## The e2e scenario being reproduced

- One EVPN L2VNI is stretched over two VTEPs. In the e2e, both VTEPs are grout
  with FRR 10.7.1 and dplane_grout. Bridges have `neigh_suppress on
  neigh_snoop on` and an anycast gateway (same IP and MAC on every VTEP).
  Nexthop config: `grcli nexthop config set lifetime 30 unreachable 60
  ucast-probes 3 bcast-probes 3`.
- old-owner sits behind VTEP A and holds VIP .10. new-owner sits behind VTEP B.
  Both owners have fixed MACs. There is one observer host behind each VTEP.
- The move happens with no gap: `ip addr del` on old-owner, then `ip addr add`
  on new-owner, then a burst of 5 gratuitous ARPs (keepalived
  `garp_master_repeat`). old-owner does not announce anything when it gives the
  VIP up.
- Success means every ARP reply for the VIP seen by each observer carries
  new-owner's MAC. The observers send `arping -b`; `-b` keeps the requests
  broadcast, so a VTEP that answers from its EVPN cache is caught as well.
  Reachability alone is not enough: the owners forward IP traffic, so
  old-owner can relay traffic to new-owner and hide stale VTEP tables.
- e2e failure on unpatched grout v0.19.3: the observer behind VTEP B receives
  two replies to each request, one from new-owner and one from grout with the
  stale MAC: `["…:03", "…:02", "…:03", "…:02"]`.

## Root cause (already fixed, uncommitted)

`suppress_arp_req()` answered new-owner's gratuitous ARP (sip == tip) from the
REMOTE nexthop with old-owner's MAC. As a result the GARP was never flooded to
VTEP A, so A kept advertising the old MAC+IP. Because the nexthop is REMOTE,
`arp_probe_input_cb()` never makes it LOCAL. iputils/busybox arping then sent
its remaining GARPs unicast to the stale MAC.

The fix floods instead of answering in three cases: sip == tip, sip == 0
(RFC 5227 probe), and an NS with an unspecified source (DAD). With the fix
applied, these pass: `evpn_vip_move_frr_test`, `bridge_neigh_suppress_test`,
`evpn_neigh_suppress_frr_test` and `arp_ndp_test`.

## Existing starting point

`smoke/evpn_vip_move_frr_test.sh` (staged) already covers the move from a host
behind a Linux+FRR peer (`evpn-peer`, host-a) to a host behind grout (host-b).
It checks zebra's `show evpn arp-cache` on both sides plus a ping from host-a.
It has no observers, no fixed MACs, no proxied-reply check and no anycast
gateway. Use it as the template (bgp_evpn helper, `wait_arp_cache`,
`dump_state`).

## What to build

Prefer extending `evpn_vip_move_frr_test.sh` over adding a new file, unless the
result becomes hard to read.

1. Pin the MACs with `ip link set ... address`: for example
   `02:00:00:00:00:02` on host-a (old owner) and `02:00:00:00:00:03` on host-b
   (new owner). Failure output then shows which owner each reply came from.
2. Add an observer host behind each VTEP: host-c on the grout bridge (new
   `create_interface ... domain br100` port) and host-d on evpn-peer's br100
   (veth, like host-a). Before the move, the observers must have already
   resolved the VIP, so that grout holds the REMOTE nexthop.
3. Use grout's nexthop config from the e2e (above). Add the anycast gateway
   only if it is needed to reproduce the bug.
4. Perform the move with no gap: del on host-a, add on host-b, then
   `arping -U -c5 -I x-p1 $vip` on host-b. Send no traffic from host-a.
5. Add a helper `vip_reply_macs <ns> <dev>` that runs
   `arping -b -c2 -w3 -I <dev> $vip` and extracts the MAC from every
   `reply from ... [mac]` line. Retry it for about 10 s. On each observer,
   fail if any reply's MAC differs from host-b's MAC. Include the full list
   of reply MACs in the `fail` message. Keep the `wait_arp_cache` checks
   for zebra state on both sides.
6. Don't check the result with `ip neigh` on the observers. Their tables keep
   only the last reply, GARPs can update an existing entry, and TCP or ping
   traffic relayed by the old owner confirms a stale entry indefinitely.

## Verification (required)

- Build with `ninja -C build`. Run with `sudo smoke/<name>.sh build`. The log
  is large, so strip colours with `sed 's/\x1b\[[0-9;]*m//g'` and grep for
  `^fail:` and `nh (new|update|del):.*10\.0\.0\.10`.
- Without the fix, the test must fail at the observer check behind grout, with
  both MACs in the reply list. To revert the fix temporarily, save it first
  with `git diff modules/l2/datapath/bridge_neigh_suppress.c > <scratch>/fix.patch`,
  then run `git checkout` on that file, rebuild, run the test, and restore
  with `git apply <scratch>/fix.patch`. Never use bare `git stash`.
- With the fix, the new test and the four tests listed above must pass.
- Report both runs (the failing output and the passing output) faithfully.

## Out of scope / UNVERIFIED follow-up

The e2e environment showed a second problem on the old VTEP when that VTEP is
grout:
- When its learned `.10` entry ages out, its unicast probes to old-owner get
  no answer.
- Its broadcast probe goes out over VXLAN, and the other VTEPs answer it from
  their EVPN REMOTE cache with old-owner's MAC.
- The old VTEP marks the entry reachable again, roughly every 30 s,
  indefinitely.

Reproducing this needs grout as the OLD VTEP, so the move goes from grout's
host to the peer's host. Linux `neigh_suppress` on evpn-peer's vxlan port may
or may not proxy those probes the way grout does. Only reproduce this if asked.
A possible fix direction is not proxy-answering requests that arrive from a
VXLAN port.
