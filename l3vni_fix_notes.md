# Fix: L3VNI mapping overwrite by L2 VNI

## Root cause

`l3vni_map.c` maintains a single VRF→VXLAN hash table. When a VXLAN interface
enters VRF mode, `l3vni_set(vrf_id, iface_id)` overwrites any existing mapping
for that VRF. When an L2 VNI is created in VRF mode (all new interfaces start
in `GR_IFACE_MODE_VRF` per `iface.c:208`) and then moved to a bridge, the
L3VNI mapping is corrupted and never restored.

Event sequence:
1. vni-l3 IFACE_ADD (VRF): `l3vni_set(vrf, l3)` — correct mapping
2. vni-l2 IFACE_ADD (VRF): `l3vni_set(vrf, l2)` — OVERWRITES
3. vni-l2 POST_RECONFIG (BRIDGE): no cleanup — mapping stays wrong

## Fix: files to modify

### frr/l3vni_map.h

Add declaration:
```c
void l3vni_del_by_iface(uint16_t iface_id);
```

### frr/l3vni_map.c

Add a reverse hash table (iface_id → vrf_id) to track all VXLAN interfaces
that have been registered via `l3vni_set`. Use the same PREDECL_HASH/DECLARE_HASH
pattern as the existing forward table.

```c
PREDECL_HASH(l3vni_rev);

struct l3vni_rev_entry {
    struct l3vni_rev_item item;
    uint16_t iface_id;
    uint16_t vrf_id;
};
```

Modify `l3vni_set(vrf_id, iface_id)`:
- Also add an entry to the reverse table (skip if already present with same vrf)

Implement `l3vni_del_by_iface(iface_id)`:
- Look up iface_id in reverse table → get vrf_id
- Remove from reverse table
- If forward table maps vrf_id → this iface_id, remove the forward entry
- Scan reverse table (`frr_each_safe`) for another entry with the same vrf_id
- If found, re-register it in the forward table as the new L3 VNI

Modify `l3vni_del(vrf_id)`:
- Remove from forward table (unchanged)
- Also remove ALL reverse entries with matching vrf_id

### frr/if_grout.c

In `grout_link_change`, inside the `if (new)` block:
- After the mode switch, when `zif_type == ZEBRA_IF_VXLAN` and mode is NOT
  `GR_IFACE_MODE_VRF` (BRIDGE, BOND, etc.), call `l3vni_del_by_iface(gr_if->id)`

In the delete path (around line 226):
- Replace the conditional `if (gr_vxlan != NULL && gr_if->mode == GR_IFACE_MODE_VRF)`
  with an unconditional `l3vni_del_by_iface(gr_if->id)` for all VXLAN interfaces,
  since the interface may have been registered while in VRF mode but is now in
  BRIDGE mode at deletion time.

## Correctness for all scenarios

Scenario A — L3 VNI created first:
1. l3 ADD (VRF): fwd={vrf→l3}, rev={l3→vrf}
2. l2 ADD (VRF): fwd={vrf→l2}, rev={l3→vrf, l2→vrf}
3. l2 RECONFIG (BRIDGE): del_by_iface(l2) removes l2 from rev,
   finds l3 as fallback → fwd={vrf→l3} ✓

Scenario B — L2 VNI created first:
1. l2 ADD (VRF): fwd={vrf→l2}, rev={l2→vrf}
2. l3 ADD (VRF): fwd={vrf→l3}, rev={l2→vrf, l3→vrf}
3. l2 RECONFIG (BRIDGE): del_by_iface(l2) removes l2 from rev,
   fwd already maps to l3 → no change needed ✓

Startup sync: interfaces arrive with final mode. L2 VNIs in BRIDGE mode
don't trigger l3vni_set. No conflict.

## Verification

Run the new smoke test:
```
sudo smoke/evpn_l2l3vni_frr_test.sh build
```

Also run existing tests to verify no regression:
```
sudo smoke/evpn_l3vpn_frr_test.sh build
sudo smoke/evpn_vxlan_frr_test.sh build
```
