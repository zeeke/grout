
With EVPN `neigh_suppress on`, a VTEP answers a **gratuitous ARP** from its
REMOTE nexthop cache instead of flooding it. When a floating IP (VIP) moves
from a host behind VTEP A to a host behind VTEP B (keepalived-style failover),
VTEP B replies to the new owner's GARP with the **old** owner's MAC. The GARP
never reaches VTEP A, VTEP B never learns the VIP as local, and both VTEPs keep
the stale MAC+IP binding for minutes.

## Topology

```
host-a --- vtep-a ===( spine: VXLAN + BGP EVPN )=== vtep-b --- host-b
02:..:0a                                                       02:..:0b
```

- Both VTEPs: grout + FRR, one L2VNI (100), bridge with
  `neigh_suppress on neigh_snoop on`.
- `grcli nexthop config set lifetime 30 unreachable 60 ucast-probes 3 bcast-probes 3`

## Steps

1. `10.0.0.10/32` on host-a. vtep-b installs it as a REMOTE nexthop
   (`mac=02:00:00:00:00:0a flags=remote neigh`) from the EVPN type-2 route.
2. Move with no gap, like keepalived:
   ```
   host-a# ip addr del 10.0.0.10/32 dev eth0
   host-b# ip addr add 10.0.0.10/32 dev eth0
   host-b# arping -U -c5 -I eth0 10.0.0.10
   ```
   host-a sends nothing when it releases the VIP.
3. Expected: vtep-b learns `10.0.0.10` as local with `02:00:00:00:00:0b`,
   advertises it over EVPN, and vtep-a ends up with a REMOTE nexthop pointing
   at `02:00:00:00:00:0b`.

## Actual behavior

vtep-b proxy-answers the first (broadcast) GARP with the stale MAC, and does
not flood it:

```
[vtep-b grout] [rx p1] 02:00:00:00:00:0b > ff:ff:ff:ff:ff:ff / ARP announce 10.0.0.10 is at 02:00:00:00:00:0b
[vtep-b grout] [tx p1] 02:00:00:00:00:0a > 02:00:00:00:00:0b / ARP reply 10.0.0.10 is at 02:00:00:00:00:0a
```

As a consequence:

- vtep-b's nexthop stays REMOTE.
- vtep-a keeps its locally learned entry with the old MAC. When it ages out,
  the unicast probes to `02:..:0a` get no answer, but the broadcast probe
  goes over VXLAN and **vtep-b answers it from its stale REMOTE cache**. vtep-a
  marks the entry reachable again, every ~36 s:
  ```
  [vtep-a grout] [tx p1] 82:87:e6:5c:f5:26 > 02:00:00:00:00:0a / ARP request who has 10.0.0.10? tell 10.0.0.251   (x3, no answer)
  [vtep-a grout] [tx p1] 82:87:e6:5c:f5:26 > ff:ff:ff:ff:ff:ff / ARP request who has 10.0.0.10? tell 10.0.0.251
  [vtep-b grout] [tx p0] ... VXLAN vni=100 / Ethernet 02:00:00:00:00:0a > 82:87:e6:5c:f5:26 / ARP reply 10.0.0.10 is at 02:00:00:00:00:0a
  ```

State 60 s after the move:

```
vtep-a: main      learn   br100  L3  family=ipv4 addr=10.0.0.10 state=reachable mac=02:00:00:00:00:0a flags=neigh
vtep-b: main  1   zebra   br100  L3  family=ipv4 addr=10.0.0.10 state=reachable mac=02:00:00:00:00:0a flags=remote neigh
```

## Proposed fix

Flood instead of proxy-answering when `sip == tip` or `sip == 0`:

```patch
diff --git a/modules/l2/datapath/bridge_neigh_suppress.c b/modules/l2/datapath/bridge_neigh_suppress.c
index 61db35a1..3bc734a2 100644
--- a/modules/l2/datapath/bridge_neigh_suppress.c
+++ b/modules/l2/datapath/bridge_neigh_suppress.c
@@ -51,6 +51,13 @@ suppress_arp_req(struct rte_mbuf *m, struct rte_ether_hdr *eth, const struct ifa
        if (arp->arp_opcode != RTE_BE16(RTE_ARP_OP_REQUEST))
                return FLOOD;
 
+       // Never answer a gratuitous ARP or an address probe (RFC 5227): the
+       // sender announces or checks its own address. Answering with the cached
+       // MAC would claim that address for another host and keep the
+       // announcement from reaching the VTEP that still advertises it.
+       if (arp->arp_data.arp_sip == arp->arp_data.arp_tip || arp->arp_data.arp_sip == 0)
+               return FLOOD;
+
        nh = nh4_lookup(bridge->vrf_id, arp->arp_data.arp_tip);
        if (!nexthop_is_suppressable(nh))
                return FLOOD;
```

## Reproducer

Self-contained script (podman, two grout+FRR VTEPs, two hosts, a spine
bridge). Run with:

```
sudo GROUT_IMAGE=quay.io/grout/grout:0.19.3 bash evpn-vip-move-repro.sh  # KO 
sudo GROUT_IMAGE=quay.io/apanatto/grout:0.19.3-garp-fix bash devtools/evpn-vip-move-repro.sh # OK
```
