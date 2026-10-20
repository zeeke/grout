# grout drops `GR_EVENT_FDB_ADD` for zebra → missing EVPN type-2 routes

Everything needed to understand, reproduce and fix the grout bug behind the
`e2etests (helm-grout)` failure in
https://github.com/zeeke/openperouter/actions/runs/39400495021.

## The problem in one paragraph

grout's datapath learns a MAC and queues a `GR_EVENT_FDB_ADD` on the control
queue. If that queue is drained while grout is handling an API request from
zebra (e.g. `GR_NH_DEL` → `nexthop_destroy()` → `control_queue_drain()`),
grout treats the queued event as caused by zebra. zebra subscribed with
`suppress_self_events = true`, so grout doesn't send it the event. zebra never
learns the MAC and bgpd never advertises its EVPN type-2 route. grout never
re-sends the event while the host keeps talking, so the loss is permanent.
Remote PEs that receive traffic for that host can't forward it.

## Layout

| path | content |
|---|---|
| `grout-issue.md` | issue text ready to file on https://github.com/DPDK/grout: summary, reproducer, CI findings, root cause, fix |
| `evidence/ci-run/` | evidence from the failing CI run: README with the chain of evidence, extracted excerpts `01`–`07`, raw logs, and `extract-evidence.sh` to regenerate the excerpts |
| `reproducer/shell-frr/` | **main reproducer**: grout smoke test using only `grcli`, `vtysh` and `ip` (`evpn_fdb_event_lost_frr_test.sh`), plus the patch adding it to grout |
| `reproducer/api-client/` | stronger reproducer: small API client `fdb_event_watch.c` and its smoke test, plus the patch (`meson.build` + `smoke/`) |
| `fix/` | proposed grout fix: clear the requesting client's PID while the control queue is drained |
| `results/` | full logs of every reproducer run (unpatched and patched) and a results summary |

All three patches apply cleanly on grout `main` (846ee040). They were
generated against 0794bf3b, where the code involved is identical.

## Reproduce

From a grout checkout built with FRR (`meson setup build -Dfrr=enabled`):

```sh
git apply /path/to/grout-fdb-event-loss/reproducer/shell-frr/0001-smoke-evpn-fdb-event-lost.patch
sudo smoke/evpn_fdb_event_lost_frr_test.sh build
```

Expected on an affected grout: phase 1 passes, phase 2 fails with a few
`learned by grout, unknown to zebra: <mac>` lines (5 out of 5 runs failed here,
2–5 of 80 MACs lost per run).

Stronger variant, no FRR needed:

```sh
git apply /path/to/grout-fdb-event-loss/reproducer/api-client/0001-smoke-fdb-event-self-suppress.patch
meson setup build && ninja -C build grout grcli fdb_event_watch
sudo smoke/fdb_event_self_suppress_test.sh build
```

Expected on an affected grout: control run 100/100 notified, then
`injected=100 learned=100 notified=<few> missing=<most>`.

The build dir must be in a short path: FRR puts its sockets under
`<builddir>/frr_install/var/run/frr/`, and Unix socket paths are limited to
108 bytes.

## Status

| claim | verified |
|---|---|
| Mechanism (code paths in `main/api.c`, `main/event.c`, `main/control_queue.c`, `modules/infra/control/nexthop.c`, `modules/l2/control/fdb.c`, `frr/zebra_dplane_grout.c`) | read on v0.19.0 and `main` 846ee040 |
| CI failure matches it (MAC learned in grout, no FDB event in zebra, no type-2 route) | yes, see `evidence/ci-run/` |
| Shell reproducer fails on unpatched grout | yes, 5 out of 5 runs |
| grout emitted the lost events, only zebra's copy was suppressed | yes, all 18 missing MACs were received by the harness's `grcli events` subscriber (`results/missing-macs-event-delivery.txt`) |
| API-client reproducer fails on unpatched grout | yes, 3 out of 3 runs (90–99 of 100 lost) |
| Fix makes the API-client reproducer pass | yes, 5 out of 5 runs |
| Fix makes the shell reproducer pass | **not run yet**: needs a grout+FRR build in a short path |
| Exact moment pod2's MAC was learned in CI | **not recorded**: grout logs neither timestamps nor FDB learning. The window contains zebra's `GR_NH_DEL` calls |

## Impact on OpenPERouter

`Dockerfile.grout` installs the grout v0.19.0 release RPMs, so nothing on our
side fixes this. Options: bump grout once a release has the fix, or build
grout with the patch until then. A workload hits it whenever its first frame
arrives while zebra is deleting a nexthop. zebra re-installs its `169.254.0.1`
rmac nexthops every ~10 s in the SRv6 setup, so the window recurs constantly.
The e2e test should stay as it is: it is catching a real datapath bug.
