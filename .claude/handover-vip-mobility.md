# Handover: EVPN VIP mobility (grout branch `us/vip-mac-evpn-bug`)

Continue this work in `~/dev/github.com/DPDK/grout`. Read this whole file first;
everything below was verified by running the tests unless marked UNVERIFIED.
Nothing is committed. Run smoke tests with `sudo smoke/<name>.sh build`
(`build/` = grout + FRR 10.6.2; `build-frr107/` = FRR 10.7.1). Rebuild with
`ninja -C build`. The test log is huge: pipe through
`sed 's/\x1b\[[0-9;]*m//g'` into a file and grep for `^fail:`, `nh (new|update|del):.*10\.0\.0\.10`
and `grout_neigh_notify`.

## Goal

A keepalived-style VIP move between two EVPN VTEPs (old owner silently drops
the IP, new owner sends gratuitous ARPs) must converge when one VTEP is grout
and the other is Linux+FRR. Reference test: `smoke/evpn_vip_mobility_frr_test.sh`
(evpn-peer = kernel VTEP with host-a, grout = VTEP with host-b; VIP 10.0.0.10;
step 1 host-a owns, step 2 move to host-b, step 3 move back to host-a).

## Root cause (applies to kernel and grout alike)

The new VTEP holds a remote EVPN entry for the VIP and ignores the new owner's
gratuitous ARPs:
- kernel: zebra installs it as `extern_learn NOARP proto zebra`; received ARPs
  never override NOARP, whatever `arp_accept` is.
- grout: `arp_probe_input_cb()` (`modules/ip/control/nexthop.c`) never updates
  a `GR_NH_F_REMOTE` nexthop.
Convergence requires the OLD VTEP to stop advertising (its local entry gets
updated to a remote MAC, or fails), so zebra withdraws the Type-2 route; then
the new owner's NEXT announcement is learned.

## Kernel-only baseline (for the upstream FRR/kernel issue)

`smoke/evpn_vip_mobility_kernel_frr_manualtest.sh [<frr_prefix>]` — two
Linux+FRR VTEPs, no grout, same topology/steps. Env: `ARP_ACCEPT=0|1`,
`VERBOSE=1`, `TRAFFIC=none|hosts|vtep`. Results (identical on FRR 10.6.2 and
10.7.1, kernel 7.1.9):
- none / hosts: step 2 fails with arp_accept 0 and 1.
- vtep (old VTEP pings the VIP so its STALE entry -> FAILED -> withdraw):
  step 2 passes only with arp_accept=1; step 3 fails because the probe is only
  triggered in step 2.
So the kernel datapath does NOT support the move by itself. OpenPERouter makes
it work with `arp_accept=1` + `internal/hostnetwork/bridgerefresh` (pings STALE
neighbors every 30s). The user wanted to use this script for an upstream issue;
the honest framing is "kernel needs periodic probing to converge", not
"kernel supports it". `smoke/evpn_ip_mobility_kernel_frr_manualtest.sh` is an
older, more elaborate variant (anycast gateway, several modes); untracked too.

## Uncommitted grout changes

1. `modules/l2/datapath/bridge_neigh_suppress.c` — VERIFIED IMPORTANT FIX.
   ARP suppression answered gratuitous ARPs (sip == tip) with the remote MAC,
   telling the new owner its own IP belongs to someone else. It also prevented
   the GARP from being flooded to the old VTEP, and iputils arping then sent
   all further GARPs unicast to the stale MAC (never snooped). Now: no reply
   for sip == tip or sip == 0 (RFC 5227 probe), and no NA for an NS with
   unspecified source (DAD); those are flooded. Matches Linux bridge behaviour.
   Effect: step 2 of the original test now passes (old kernel VTEP receives
   the flooded GARP, updates its local entry to host-b's MAC, withdraws).
   No unit test yet.
2. `modules/infra/control/l3_nexthop.c` + `frr/rt_grout.c` — UNEXERCISED.
   A learned nexthop going STALE -> FAILED now pushes
   `GR_EVENT_NEXTHOP_UPDATE`; `grout_neigh_notify()` turns a FAILED state into
   `DPLANE_OP_NEIGH_IP_DELETE`, like a kernel neighbor in NUD_FAILED. The
   nexthop and its routes are kept on purpose: commit c4a6c173 removed
   destroy-after-`lifetime_unreachable_sec` because it nuked routing tables
   (static routes can resolve to learned nexthops). `lifetime_unreachable_sec`
   is now unused config. This path matters when an address disappears with
   nobody answering (grout would otherwise advertise it forever). No test has
   hit it: in every run someone answered grout's probe. Needs a dedicated test
   (e.g. VIP removed everywhere, short lifetime, expect Type-2 withdrawn).
3. `smoke/evpn_vip_mobility_frr_test.sh` — user's own edit (`check 10` -> `check 60`
   in step 2). Note: it uses `arping -c3 -i0.2`; iputils 20250605 rejects
   fractional intervals ("invalid argument") and `|| :` hides it, so NO GARPs
   are sent on this machine. Use `-i1`.
4. `smoke/evpn_vip_mobility_ageing_frr_test.sh` — new, PASSES but MISLEADING:
   its header claims convergence via ageing/refresher, the logs show it came
   from flooded GARPs and incidental ARP exchanges. Proposed to delete it.

## Results of the original test with fix 1 (`-i1`)

- default config: steps 1-2 pass, step 3 fails.
- plus `grcli nexthop config set lifetime 2`: step 3 still fails, but closer:
  grout probes the VIP, host-a answers over VXLAN, grout updates its learned
  nexthop to host-a's MAC, zebra marks it `local inactive` (MAC is remote) and
  withdraws; evpn-peer then has NO entry for the VIP. host-a announced only at
  `vip_add` (before the withdrawal) and evpn-peer has arp_accept=0, so nobody
  re-learns it. A repeated announcement from host-a after the withdrawal should
  complete it (UNVERIFIED).

## Next steps (proposed to the user, not yet approved)

1. Delete `smoke/evpn_vip_mobility_ageing_frr_test.sh`.
2. In `smoke/evpn_vip_mobility_frr_test.sh`: `-i0.2` -> `-i1`; add
   `grcli nexthop config set lifetime 2` before the bridge is created; in
   step 3 make host-a re-announce while polling (e.g. the
   `arping -c1 -w2 -s $vip -I x-p1 10.0.0.4` to the gateway, or periodic GARPs
   = keepalived `garp_master_refresh`). Ask the user before changing what the
   test asserts.
3. Add coverage for fix 1 (unit/smoke: GARP and ARP probe not answered by
   suppression, flooded instead; DAD NS not answered).
4. Add a test for fix 2 (FAILED learned neighbor -> Type-2 withdrawn).
5. Split into commits: suppression fix; FAILED notify; test changes. Follow the
   repo's commit style (`git log`), sign-off as the user does.

## OpenPERouter follow-up

A prompt for the OpenPERouter side was drafted at
`.claude/openperouter-grout-refresher-prompt.md`. It is OUTDATED in two points: it
assumes grout destroys FAILED nexthops after `unreachable` (now: grout reports
them FAILED to zebra, only `lifetime` matters), and it predates fix 1, which
makes the move towards grout converge without any refresher. Facts still valid:
- branch `us/grout-l2vni` in `~/dev/github.com/openperouter/openperouter`;
  grout bridges are created with `neigh_suppress on neigh_snoop on`
  (`internal/grout/grout_client.go`), and `grout_config.go` still starts the
  kernel netlink `bridgerefresh` for grout L2VNIs, which only sees the grout
  control-plane tap's kernel neighbors, not grout nexthops (UNVERIFIED on a
  running setup);
- grout's own `l3_age()` already probes STALE learned nexthops without needing
  traffic; OpenPERouter's grout-side equivalent of the refresher is just
  `grcli nexthop config set lifetime <N>` (default 1200s, global setting);
- learned nexthops have no ID, so OpenPERouter cannot delete them individually.
Regenerate the prompt once the grout side is settled.
