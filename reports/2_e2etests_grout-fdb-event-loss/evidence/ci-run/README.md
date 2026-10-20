# Evidence from the failing CI run

- Run: https://github.com/zeeke/openperouter/actions/runs/39400495021
- Job: `e2etests (helm-grout)`,
  https://github.com/zeeke/openperouter/actions/runs/39400495021/job/118559079906?pr=10
- Commit: f33e5d7ed572040c163466f48480a0af8ea21754 (branch `grout-dev`, PR zeeke/openperouter#10)
- grout/FRR in the router image: v0.19.0 release RPMs (`Dockerfile.grout`), FRR 10.7.1
- Failing spec: `SRV6 routes between bgp and the fabric should create two pods
  connected to the l2 overlay that can reach each other via L2VNI and hosts via
  L3VPN [It] OVS bridge managed for single stack ipv4 [grout-support]`
  (`e2etests/tests/l3vpn_l2.go:375`). The same spec passed in the `grout` and
  `operator-grout` jobs of the same run, so the failure is a race.
- Artifacts: `kind-logs-helm-grout` (test dump directory) and
  `e2e-reports-helm-grout`.

## Topology

| node | router pod | VTEP | SRv6 SID block | test pod |
|---|---|---|---|---|
| pe-kind-control-plane | `openperouter-router-qts9b` | 100.65.0.0 | fd00:0:32 | pod1 192.171.24.2 `46:cd:e2:e6:d1:6c` |
| pe-kind-worker | `openperouter-router-2jmrq` | 100.65.0.1 | fd00:0:33 | pod2 192.171.24.3 `f6:ce:79:73:0c:48` |
| pe-kind-worker2 | `openperouter-router-nqgwj` | 100.65.0.2 | fd00:0:34 | — |

Each node has L2VNI 110 (grout bridge `br-pe-110`, anycast gateway
192.171.24.1 with the same MAC `00:f3:00:00:00:6f` on every node) in VRF
`red`. VRF `red` is exported over an SRv6 L3VPN to `leafSRV6`, which hosts
hostSRV6Red (192.170.20.2).

## What failed

pod2 → hostSRV6Red (`curl 192.170.20.2:8090`) times out for 60 s. pod1 →
hostSRV6Red works after ~13 s of retries.

## Chain of evidence

| # | file | shows |
|---|---|---|
| 1 | `01-test-failure.txt` | timeline of the failing spec: pods created 10:08:12, checks start 10:08:34, pod2 fails until 10:09:47 |
| 2 | `02-pods.txt` | pod placement |
| 3 | `03-leafSRV6-ecmp-return-path.txt` | leafSRV6 sends return traffic for 192.171.24.0/24 over ECMP to the SIDs of all 3 nodes. A node that receives traffic for pod2 but doesn't host it needs a type-2 route to forward it over VXLAN |
| 4 | `04-evpn-type2-per-node.txt` | pod1's type-2 route is on every node; **pod2's type-2 route is on none**, not even pe-kind-worker |
| 5 | `05-grout-state.txt` | on pe-kind-worker, **grout has learned pod2's MAC** (`f6:ce:79:73:0c:48 pe-110 learn`) and neighbor (reachable). On the other nodes, neighbor 192.171.24.3 is `state=failed`: they ARP over VXLAN, and pod2's reply goes to its local anycast gateway MAC |
| 6 | `06-zebra-timeline-worker.txt` | zebra on pe-kind-worker: **no `GR_EVENT_FDB_ADD` for pod2's MAC** (the last FDB event is at 10:08:18.650). The first event about pod2 is a `NEXTHOP_UPDATE` with no `NEXTHOP_NEW`, right after zebra's own `GR_NH_DEL`/`GR_NH_ADD` at 10:08:33.343/.360. zebra gets ~80 neighbor updates for pod2 but never sends a MACIP to bgpd. An earlier pod with the same IP on the same node (10:05:19) got FDB_ADD and NEXTHOP_NEW normally |
| 7 | `07-zebra-timeline-control-plane-ok.txt` | contrast: pod1's MAC is notified (`grout_macfdb_change add`) and zebra hands it to bgpd (MACIP Add → type-2 UPDATE) |

Grout's own log (`raw/grout-log-*`) has no timestamps and doesn't log FDB
learning, so the exact moment pod2's MAC was learned isn't recorded. It falls
between 10:08:18.650 (last FDB event received) and 10:08:34.179 (first neighbor
event), a window that contains zebra's `GR_NH_DEL` calls at 10:08:22.6,
10:08:23.3, 10:08:32.6 and 10:08:33.3.

## Files

`extract-evidence.sh` regenerates `01`–`07` from `raw/`:

| raw file | source in the CI artifact |
|---|---|
| `e2e-job-log-tail.txt.gz` | last ~1100 lines of the job log (`gh run view --log-failed`) |
| `test-pods.yaml` | `pod-list-namespace-test-namespace.log` |
| `dump-timestamp.txt` | `timestamp` (when the dump was taken: 10:10:22) |
| `frrdump-router-<node>.log.gz` | `frrdump-openperouter-router-<pod>.log`: vtysh show commands plus `grcli interface/address/route/nexthop/fdb/stats show` |
| `frrdump-leafSRV6.log.gz` | `frrdump-clab-kind-leafSRV6.log` |
| `frr-log-router-<node>.log.gz` | `openperouter-system/pod_logs/openperouter-router-<pod>_frr.log`: zebra/bgpd debug log including the `GROUT:` dplane plugin messages |
| `grout-log-router-<node>.log.gz` | `openperouter-system/pod_logs/openperouter-router-<pod>_grout.log` (truncated at the start by kubectl, no timestamps) |

To fetch the full artifacts again:

```sh
gh run download 39400495021 -R zeeke/openperouter -n kind-logs-helm-grout -D kind-logs
gh run download 39400495021 -R zeeke/openperouter -n e2e-reports-helm-grout -D e2e-reports
```
