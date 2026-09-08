# Master0 does not advertise `192.168.110.2` through EVPN

Date investigated: 2026-09-08  
Affected node: `master-0.sno-lab.example.com` (`10.0.0.2`)  
Affected VNI: `210`

## Summary

Master0 learns the endpoint `192.168.110.2` and its MAC address `c6:11:d0:35:9d:1d` in Grout, but FRR Zebra does not retain the corresponding local MAC in its EVPN VNI table. Zebra consequently marks the IP neighbor as `local inactive`, and BGP does not originate an EVPN type-2 MAC/IP route for it.

The evidence shows an initialization-order race on master0: the local FDB event reached Zebra approximately 19 ms before VNI 210 was associated with tenant VRF `red`. The local FDB entry was not subsequently replayed to Zebra. Master1 and master2 have both the local MAC and neighbor in Zebra, so their neighbors are active and their type-2 routes are advertised.

## Observed effect

Master0 originates only the type-3 IMET route for VNI 210. It does not originate any of the following expected type-2 routes:

```text
[2]:[0]:[48]:[c6:11:d0:35:9d:1d]
[2]:[0]:[48]:[c6:11:d0:35:9d:1d]:[32]:[192.168.110.2]
[2]:[0]:[48]:[c6:11:d0:35:9d:1d]:[128]:[fd00:110::2]
[2]:[0]:[48]:[c6:11:d0:35:9d:1d]:[128]:[fe80::c411:d0ff:fe35:9d1d]
```

Remote EVPN peers therefore do not learn that these addresses are reachable through master0/VTEP `10.0.0.2`. This affects EVPN control-plane reachability to the access-side endpoint; it does not mean that master0 failed to learn the endpoint in the Grout datapath.

## Evidence

### 1. The endpoint exists in the Grout datapath

Command:

```bash
sudo podman exec controller grcli --socket /var/run/grout/grout.sock fdb show
```

Relevant output on master0:

```text
BRIDGE     MAC                VLAN  IFACE        VTEP  FLAGS  AGE
br-pe-210  c6:11:d0:35:9d:1d        t_ws887x.42        learn  0
```

Command:

```bash
sudo podman exec controller grcli --socket /var/run/grout/grout.sock nexthop show
```

Relevant output:

```text
red  learn  br-pe-210  L3  family=ipv4 addr=192.168.110.2 state=reachable mac=c6:11:d0:35:9d:1d
```

Thus both the access-side MAC and IPv4 neighbor are known and reachable in Grout.

### 2. Zebra has the IP neighbor but marks it inactive

Command:

```bash
sudo podman exec frr vtysh -c "show evpn arp-cache vni 210"
```

Relevant output on master0:

```text
Neighbor                  Type   Flags State     MAC
192.168.110.2             local        inactive  c6:11:d0:35:9d:1d
fd00:110::2               local        inactive  c6:11:d0:35:9d:1d
fe80::c411:d0ff:fe35:9d1d local        inactive  c6:11:d0:35:9d:1d
```

`local inactive` is reported by the EVPN ARP/neighbor table. It is not a status displayed in `show bgp l2vpn evpn`.

### 3. Zebra is missing the associated local MAC

Command:

```bash
sudo podman exec frr vtysh -c "show evpn mac vni 210"
```

Output on master0:

```text
Number of MACs (local and remote) known for this VNI: 2
MAC               Type    Intf/Remote ES/VTEP
7e:2a:cf:06:3b:ac remote  10.0.0.4
fa:a8:b4:6c:c0:7e remote  10.0.0.3
```

The locally learned `c6:11:d0:35:9d:1d` is absent. An EVPN neighbor is active only when Zebra can associate it with an active local MAC entry. Without that association, BGP does not receive an eligible local MAC/IP route to originate.

### 4. Zebra receives repeated neighbor notifications

FRR logs on master0 contain repeated events such as:

```text
ZEBRA: GROUT: grout_neigh_notify: add neigh iface=5 192.168.110.2 c6:11:d0:35:9d:1d
ZEBRA: GROUT: grout_neigh_notify: add neigh iface=5 fd00:110::2 c6:11:d0:35:9d:1d
ZEBRA: GROUT: grout_neigh_notify: add neigh iface=5 fe80::c411:d0ff:fe35:9d1d c6:11:d0:35:9d:1d
```

This confirms that the failure is not the absence of neighbor notifications. The missing state is the local MAC entry in Zebra's EVPN MAC table.

### 5. Initialization ordering on master0

Relevant master0 FRR log sequence:

```text
09:56:52.749 ZEBRA: GROUT: grout_macfdb_change: add bridge=5 iface=7 mac=c6:11:d0:35:9d:1d vlan=0 vtep=(null)
09:56:52.768 BGP: Rx VNI add VRF default VNI 210 tenant-vrf red SVI ifindex 7
```

The local FDB notification arrived approximately 19 ms before VNI 210 was fully associated with tenant VRF `red`. Although Grout retained the learned FDB entry, Zebra did not retain it in the VNI MAC table and no later local-MAC replay is visible.

### 6. Comparison with unaffected nodes

Master1:

```text
show evpn mac vni 210:
fa:a8:b4:6c:c0:7e local  t_ws887x.42

show evpn arp-cache vni 210:
192.168.110.3 local  active  fa:a8:b4:6c:c0:7e
```

Master2:

```text
show evpn mac vni 210:
7e:2a:cf:06:3b:ac local  t_yqkh4y.42

show evpn arp-cache vni 210:
192.168.110.4 local  active  7e:2a:cf:06:3b:ac
```

Both unaffected nodes have a local MAC in Zebra, an active local neighbor, and corresponding EVPN type-2 advertisements.

## Conclusion

The problem is at the Grout-to-Zebra local-FDB synchronization boundary. On master0, the local MAC event was delivered before the VNI-to-VRF association was ready. Zebra did not retain or later recover that MAC entry, even though Grout continued to hold it and continued sending neighbor notifications. The missing Zebra MAC leaves all IPs associated with that MAC inactive and prevents BGP EVPN type-2 origination.

The configured SVI address `192.168.110.1/24` and `Advertise-svi-macip: No` are unrelated: `192.168.110.2` is an access-side endpoint, not the SVI address.
