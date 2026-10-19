Work on branch `us/grout-l2vni`. Goal: make EVPN VIP mobility converge on L2VNIs when the dataplane is grout, the same way the kernel dataplane does today via `internal/hostnetwork/bridgerefresh`.

## Background (verified, do not re-derive)

VIP mobility scenario (keepalived style): host-a behind VTEP-A owns a VIP, then silently drops it; host-b behind VTEP-B adds it and only sends gratuitous ARPs.

- The new VTEP cannot learn the VIP from the GARPs while it still holds the remote (EVPN) entry for it:
  - kernel: zebra installs the remote MAC+IP as `extern_learn NOARP proto zebra`; received ARPs never override a NOARP entry, whatever `arp_accept` is.
  - grout: `arp_probe_input_cb()` (grout `modules/ip/control/nexthop.c`) never updates a nexthop flagged `GR_NH_F_REMOTE` (or LOCAL). With `neigh_snoop on` it only *creates* a learned nexthop when none exists.
- So convergence only happens once the OLD VTEP declares its local entry dead and zebra withdraws the Type-2 route; then the new owner's next GARP is learned (kernel needs `arp_accept=1`, grout needs `neigh_snoop on`, both already set by OpenPERouter).
- Kernel mode gets this from the bridge refresher: every 30s it pings STALE neighbors on `br-pe-<vni>`; dead ones go PROBE -> FAILED and zebra withdraws them. Verified with a kernel-only reproducer: with arp_accept=1 + probing from the old VTEP the move converges, without probing it never does.

## Grout facts relevant to the design

- Bridge is created in `internal/grout/grout_client.go` with `neigh_suppress on neigh_snoop on`. `internal/controller/routerconfiguration/grout_config.go` calls `bridgerefresh.StartForVNI()` for grout L2VNIs too.
- That refresher uses netlink on the kernel netdev named `br-pe-<vni>`. In grout mode that netdev is grout's control-plane tap: its kernel neighbor table only contains what the kernel itself talked to, NOT grout's learned nexthops. Verify this on a running grout setup (`ip -n <ns> neigh show dev br-pe-<vni>` vs `grcli nexthop show`); I expect the refresher to be a no-op for VIP mobility in grout mode.
- Grout already has a built-in refresher: `l3_age()` (grout `modules/infra/control/l3_nexthop.c`) runs every second over learned nexthops (`origin learn`): REACHABLE -> STALE after `lifetime` seconds, then actively solicits STALE ones and marks them FAILED after `ucast-probes + bcast-probes` unanswered probes. Unlike the kernel, it does not need traffic to start probing.
- Tunables: `grcli nexthop config set (lifetime LIFE),(unreachable UNREACH),(ucast-probes UCAST),(bcast-probes BCAST)` (read with `grcli -j nexthop config show`, check exact syntax). Defaults: lifetime 1200s, unreachable 60s, 3+3 probes. These are global, not per bridge.
- Learned nexthops have no ID (`nexthop_id_get()` skips LEARN/INTERNAL), so OpenPERouter cannot delete one individually; `grcli nexthop flush origin learn` is all-or-nothing. Do not build a workaround around deleting nexthops.
- KNOWN GROUT GAP (fixed separately in grout, not in this task): a FAILED learned nexthop is never destroyed and no event reaches zebra, so the Type-2 route is never withdrawn, even though `unreachable` is documented as "duration after last unreplied probe before it is destroyed". Until that lands, the grout side cannot converge when grout is the OLD VTEP. Write the code assuming grout honours `unreachable`; make the e2e test for that direction skip/pending with a pointer to the grout issue rather than hacking around it.

## Task

1. Confirm (or refute) that the netlink bridge refresher does nothing useful in grout mode. If confirmed, stop starting it for grout L2VNIs (keep the kernel path unchanged) and remove the now-dead start/stop calls from `grout_config.go`.
2. Implement the grout equivalent: configure grout's nexthop ageing so learned neighbors are probed at kernel-like cadence. Proposal: lifetime 30s (matches `bridgerefresh.DefaultRefreshPeriod`), unreachable short enough to withdraw within ~1 min. Put the values in named constants next to the grout client, apply them idempotently in the grout reconcile path (read current config, set only on drift), and log at info when changed. Consider whether a global setting is acceptable given underlay nexthops are affected too; justify the choice in a code comment.
3. Unit tests for the new grout client method(s) following the existing `grout_client_test.go` style (fake exec).
4. E2E: add a VIP mobility test for L2VNI in grout mode modeled on `e2etests/tests/bridgerefresh.go`: two hosts on the same L2VNI behind different VTEPs, move an IP with `ip addr del` / `ip addr add` + `arping -U -c3`, assert the Type-2 MAC+IP route moves to the new VTEP's next hop and the IP is reachable from a third host within a bounded time. Cover both directions; the "grout is the old VTEP" direction depends on the grout gap above.
5. Keep the diff minimal and in the style of the surrounding code. Add a release note line like the existing bridge refresher ones.

Before coding, report back: the result of step 1, the exact grcli commands/JSON you will use, and the constants you picked. Then implement.
