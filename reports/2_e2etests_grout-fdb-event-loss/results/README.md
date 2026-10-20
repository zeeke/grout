# Reproducer results

Host: Linux 7.2.9-201.fc44.x86_64, 14 CPUs. Grout built from 0794bf3b
(v0.19.3-8, local `nexthop-fixes` branch, `debugoptimized`). The code involved
in the bug is identical on upstream `main` (846ee040) and on v0.19.0.

All logs are the complete smoke test output (`set -x` trace, grout and zebra
logs), gzipped.

## Shell-only reproducer (`reproducer/shell-frr/`)

grout + zebra/bgpd, driven by `grcli`, `vtysh` and `ip` only.

| run | log | phase 1 (zebra idle) | phase 2 (zebra deleting nexthops) | `GR_NH_DEL` by zebra |
|---|---|---|---|---|
| 1 | `unpatched/shell-frr-run1.log.gz` | 0/20 missing | **4/80 missing** | 529 |
| 2 | `unpatched/shell-frr-run2.log.gz` | 0/20 missing | **5/80 missing** | 510 |
| 3 | `unpatched/shell-frr-run3.log.gz` | 0/20 missing | **4/80 missing** | 477 |
| 4 | `unpatched/shell-frr-run4.log.gz` | 0/20 missing | **3/80 missing** | 452 |
| 5 | `unpatched/shell-frr-run5.log.gz` | 0/20 missing | **2/80 missing** | 468 |

For each of the 18 MACs missing in zebra, the smoke harness's own
`grcli events` subscriber (separate process, no suppression) did receive the
`GR_EVENT_FDB_ADD`, and zebra's log has no `grout_macfdb_change: add` for it.
grout emitted the event; only zebra's copy was suppressed. See
`missing-macs-event-delivery.txt`.

Earlier variants of the same test were less reliable: with single-gateway
routes and 40 hosts brought up in a burst, 1/40 was lost in 1 run; with hosts
spread over 8 s, 2 of 3 runs failed. The committed version (4-way ECMP churn,
80 hosts one every 0.1 s) failed 5/5.

**Not run on the patched grout.** Running FRR from a build in the session
scratch directory failed for environmental reasons: its socket paths were 202
characters long, beyond the 108-byte `sun_path` limit, and even upstream's
`evpn_vxlan_frr_test.sh` hung there. Running it on the fix needs a grout+FRR
build in a short path.

## API-client reproducer (`reproducer/api-client/`)

A single process subscribes to `GR_EVENT_FDB_ADD` with
`suppress_self_events = true` and sends `GR_NH_ADD`/`GR_NH_DEL` on a second
socket, while 100 unique source MACs are injected on a bridge port.

| grout | run | log | control (`-x`, no requests) | with requests |
|---|---|---|---|---|
| unpatched | 1 | `unpatched/api-client-run1.log.gz` | 100/100 notified | **3/100 notified, 97 missing** (2014 nh add/del cycles) |
| unpatched | 2 | `unpatched/api-client-run2.log.gz` | 100/100 notified | **1/100 notified, 99 missing** (2007) |
| unpatched | 3 | `unpatched/api-client-run3.log.gz` | 100/100 notified | **10/100 notified, 90 missing** (1196) |
| patched | 1 | `patched/api-client-run1.log.gz` | 100/100 notified | 100/100 notified (2096) |
| patched | 2 | `patched/api-client-run2.log.gz` | 100/100 notified | 100/100 notified (1764) |
| patched | 3 | `patched/api-client-run3.log.gz` | 100/100 notified | 100/100 notified (1677) |
| patched | 4 | `patched/api-client-run4.log.gz` | 100/100 notified | 100/100 notified (1699) |
| patched | 5 | `patched/api-client-run5.log.gz` | 100/100 notified | 100/100 notified (1952) |

"patched" = 0794bf3b + `fix/0001-control-queue-drain-do-not-suppress-datapath-events.patch`.

## Finding the numbers in the logs

```sh
zcat unpatched/shell-frr-run1.log.gz | grep -E '^hosts=|unknown to zebra'
zcat unpatched/shell-frr-run1.log.gz | grep -c 'GR_NH_DEL: success'
zcat unpatched/api-client-run1.log.gz | grep -E '^injected=|cycles'
```
