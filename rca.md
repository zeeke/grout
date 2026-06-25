# RCA: Nexthop 62 uses vni100 instead of pe-100 for local host 192.169.10.3

## Symptom

Traffic from 192.169.10.1 to 192.169.10.3 is VXLAN-encapsulated (vni=100) instead of being forwarded directly through pe-100. The packet trace shows:

```
ip_input:  192.169.10.1 > 192.169.10.3 ttl=255 proto=TCP(6)
ip_output: 192.169.10.1 > 192.169.10.3 ttl=255 proto=TCP(6)
eth_output: 5a:f1:6e:b1:f6:c9 > 4a:f1:73:4b:dc:22 type=IP(0x0800)
iface_output: iface=vni100
vxlan_output: vni=100 vtep=192.169.10.3
vxlan_output_no_route: drop
```

192.169.10.3 is a directly-connected host on pe-100, not a remote VTEP. It should never be VXLAN-encapsulated.

## Root Cause

File: `/home/apanatto/dev/github.com/DPDK/grout/frr/rt_grout.c`, lines 716-718.

```c
case GR_NH_T_L3:
    // For L3 nexthops in VRFs with an L3VNI, redirect the iface from
    // the VRF (SVI in FRR's model) to the VXLAN interface.
    vxlan_iface_id = l3vni_get_vxlan(req->nh.vrf_id);
    if (vxlan_iface_id != GR_IFACE_ID_UNDEF)
        req->nh.iface_id = vxlan_iface_id;       // <--- unconditional override
```

This **unconditionally** overrides the nexthop's interface to the VXLAN interface (`vni100`) for every L3 nexthop in a VRF that has an L3VNI configured. It does not distinguish between remote hosts (reachable via VXLAN tunnel) and local hosts (directly connected on pe-100).

The RMAC lookup that determines whether the host is remote happens **after** this override (lines 729-733):

```c
rmac = l3vni_rmac_get(req->nh.vrf_id, &vtep);
if (rmac != NULL) {
    memcpy(&l3->mac, rmac, sizeof(l3->mac));
    l3->flags |= GR_NH_F_REMOTE;
}
```

For 192.169.10.3, `l3vni_rmac_get()` returns NULL (no RMAC cached for local hosts), so `GR_NH_F_REMOTE` is never set — but `iface_id` was already overwritten to `vni100`.

## Evidence

1. **RMAC cache has no entry for 192.169.10.3.** Only remote VTEPs (100.64.0.x, 100.65.0.0) have cached RMACs.

2. **Nexthop 62 has no `remote` flag**, confirming it's a local nexthop that was incorrectly given the VXLAN interface:
   ```
   red   21  zebra   vni100  L3  addr=100.64.0.1   mac=aa:bb:cc:00:00:65  flags=static remote  ← correct
   red   27  zebra   vni100  L3  addr=100.65.0.0   mac=ee:99:59:97:9f:fb  flags=static remote  ← correct
   red   62  zebra   vni100  L3  addr=192.169.10.3  state=reachable mac=4a:f1:73:4b:dc:22       ← BUG
   ```

3. **MAC 4a:f1:73:4b:dc:22 was learned via ARP**, not EVPN RMAC:
   ```
   arp_input_reply: reply 192.169.10.3 is at 4a:f1:73:4b:dc:22
   ```

4. **The directly-connected route correctly uses pe-100:**
   ```
   red   ipv4  192.169.10.0/24  link  type=L3  iface=pe-100
   ```

## Proposed Fix

Move the VXLAN interface override inside the `if (rmac != NULL)` blocks (for both IPv4 and IPv6), so it only applies to remote nexthops:

```c
case GR_NH_T_L3:
    vxlan_iface_id = l3vni_get_vxlan(req->nh.vrf_id);

    switch (nh->type) {
    case NEXTHOP_TYPE_IPV4:
    case NEXTHOP_TYPE_IPV4_IFINDEX:
        l3 = (struct gr_nexthop_info_l3 *)req->nh.info;
        l3->af = GR_AF_IP4;
        memcpy(&l3->ipv4, &nh->gate.ipv4, sizeof(l3->ipv4));
        vtep.ipa_type = IPADDR_V4;
        vtep.ipaddr_v4 = nh->gate.ipv4;
        rmac = l3vni_rmac_get(req->nh.vrf_id, &vtep);
        if (rmac != NULL) {
            memcpy(&l3->mac, rmac, sizeof(l3->mac));
            l3->flags |= GR_NH_F_REMOTE;
            if (vxlan_iface_id != GR_IFACE_ID_UNDEF)
                req->nh.iface_id = vxlan_iface_id;
        }
        break;
    case NEXTHOP_TYPE_IPV6:
    case NEXTHOP_TYPE_IPV6_IFINDEX:
        l3 = (struct gr_nexthop_info_l3 *)req->nh.info;
        l3->af = GR_AF_IP6;
        memcpy(&l3->ipv6, &nh->gate.ipv6, sizeof(l3->ipv6));
        vtep.ipa_type = IPADDR_V6;
        vtep.ipaddr_v6 = nh->gate.ipv6;
        rmac = l3vni_rmac_get(req->nh.vrf_id, &vtep);
        if (rmac != NULL) {
            memcpy(&l3->mac, rmac, sizeof(l3->mac));
            l3->flags |= GR_NH_F_REMOTE;
            if (vxlan_iface_id != GR_IFACE_ID_UNDEF)
                req->nh.iface_id = vxlan_iface_id;
        }
        break;
    ...
```

## Remaining Uncertainty (~10%)

It's unclear exactly what `nh->ifindex` FRR passes for nexthop 62. If FRR passes the VRF interface (`red`) rather than `pe-100`, then removing the unconditional override would leave `iface_id` pointing at the VRF interface instead of pe-100. However, grout's nexthop resolution should handle this correctly since 192.169.10.3 is directly connected on pe-100 within that VRF. Either way, the override to `vni100` is wrong for local hosts.
