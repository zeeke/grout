# FRR 10.6 to 10.7: EVPN FDB replay differences

## Scope

This note documents the dataplane changes relevant to the Grout EVPN local-MAC
initialization issue described in
[`54b3_master0-evpn-macip-incident.md`](54b3_master0-evpn-macip-incident.md).

The comparison is based on FRR 10.6.1, FRR 10.7.0, and current FRR `master`.

## Executive summary

FRR 10.6 reads EVPN local MACs through the kernel-specific FDB reader. That
reader cannot see FDB entries held only in Grout. If Grout sends its FDB event
before the EVPN VNI exists, the local MAC is lost from Zebra's EVPN table.

FRR 10.7 introduces a generic dataplane FDB-read operation. This provides the
correct extension point for non-kernel dataplanes such as Grout, but it does
not fix the problem by itself. The Grout dplane plugin must implement the new
read request and replay entries from `GR_FDB_LIST`.

## Relevant code changes

| Area | FRR 10.6.1 | FRR 10.7.0 and newer |
| --- | --- | --- |
| EVPN replay call | `macfdb_read_for_bridge()` | `dplane_fdb_read_for_bridge()` |
| Dplane operation | No generic FDB-read operation | `DPLANE_OP_FDB_READ` |
| Read context | Kernel/netlink-specific | Carries interface, bridge, VLAN, VNI, and filtering information |
| Custom dataplane support | No lifecycle replay hook | Providers can process the FDB-read request |
| Grout requirement | Existing notification path is insufficient | Grout must add `DPLANE_OP_FDB_READ` handling |

### FRR 10.6.1

The EVPN initialization path calls:

```c
macfdb_read_for_bridge(zns, ifp, zif->brslave_info.br_if,
                       vni->access_vlan);
```

This is visible in the vendored FRR source at
[`zebra/zebra_evpn.c`](subprojects/frr-frr-10.6.1/zebra/zebra_evpn.c).

Grout's plugin separately translates asynchronous FDB notifications in
[`grout_macfdb_change()`](frr/rt_grout.c), but that only works if the VNI is
already known when the notification is processed.

### FRR 10.7.0

FRR replaces the kernel-specific call with:

```c
dplane_fdb_read_for_bridge(zns, ifp, zif->brslave_info.br_if,
                           vni->access_vlan);
```

See the upstream implementation in
[`zebra/zebra_evpn.c`](https://github.com/FRRouting/frr/blob/frr-10.7.0/zebra/zebra_evpn.c).

The new operation is declared in
[`zebra/zebra_dplane.h`](https://github.com/FRRouting/frr/blob/frr-10.7.0/zebra/zebra_dplane.h):

```c
DPLANE_OP_FDB_READ,
DPLANE_OP_NEIGH_READ,
```

The request includes the bridge/interface/VLAN/VNI context through accessors
such as:

```c
dplane_ctx_get_macfdb_read_br_ifindex()
dplane_ctx_get_macfdb_read_vid()
dplane_ctx_get_macfdb_read_vni()
dplane_ctx_get_macfdb_read_mac()
```

The enqueue implementation is in
[`zebra/zebra_dplane.c`](https://github.com/FRRouting/frr/blob/frr-10.7.0/zebra/zebra_dplane.c),
including `dplane_fdb_read_for_bridge()` and the `DPLANE_OP_FDB_READ`
context creation.

## Impact on Grout

The current Grout plugin still has no `DPLANE_OP_FDB_READ` handler. Its
notification switch handles FDB add/update/delete events only:

[`frr/zebra_dplane_grout.c`](frr/zebra_dplane_grout.c)

Therefore, upgrading Zebra from 10.6 to 10.7 is not sufficient. The required
Grout-side behavior is:

1. Receive `DPLANE_OP_FDB_READ`.
2. Read Grout's current FDB, preferably filtered by bridge ID and VLAN.
3. Replay each entry through the existing local FDB translation path.
4. Complete the request only after the replay has been queued to Zebra.

Conceptually:

```c
case DPLANE_OP_FDB_READ:
    grout_fdb_read_for_bridge(ctx);
    break;
```

`grout_fdb_read_for_bridge()` should use `GR_FDB_LIST` and invoke the same
conversion used by `grout_macfdb_change(fdb, true)`. It must preserve the
entry's local/remote and static/dynamic properties rather than treating every
entry as a local MAC.

## Commit and release links

- [FRR 10.6.1 release](https://github.com/FRRouting/frr/releases/tag/frr-10.6.1)
- [FRR 10.7.0 release](https://github.com/FRRouting/frr/releases/tag/frr-10.7.0)
- [FRR 10.7.0 release commit](https://github.com/FRRouting/frr/commit/87fe21f)
- [FRR 10.6.1 to 10.7.0 comparison](https://github.com/FRRouting/frr/compare/frr-10.6.1...frr-10.7.0)
- [Current FRR `master` dplane API](https://github.com/FRRouting/frr/blob/master/zebra/zebra_dplane.h)
- [Current FRR `master` EVPN replay path](https://github.com/FRRouting/frr/blob/master/zebra/zebra_evpn.c)
- [Current upstream Grout dplane plugin](https://github.com/DPDK/grout/blob/main/frr/zebra_dplane_grout.c)

The comparison link is the most useful commit-level view because the FDB-read
API spans the dplane header, dplane implementation, and EVPN caller.

## Compatibility conclusion

| Combination | Expected result for this incident |
| --- | --- |
| FRR 10.6 + current Grout plugin | Affected |
| FRR 10.7 + current Grout plugin | New API exists, but Grout replay is still missing; do not assume fixed |
| FRR 10.7 + Grout `DPLANE_OP_FDB_READ` implementation | Intended fix path |
| FRR `master` + compatible Grout plugin | Intended fix path, subject to dplane API compatibility |

The regression test should be run after implementing the Grout handler. It
should then find the learned MAC in `show evpn mac vni 100` instead of failing
with `Zebra lost pre-existing local MAC`.
