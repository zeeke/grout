#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Robin Jarry

# Reproduce the EVPN local-MAC initialization ordering bug described in
# 54b3_master0-evpn-macip-incident.md.
#
# The access-side MAC is learned before FRR has discovered the L2 VNI. Zebra
# must replay the already learned local FDB entry when advertise-all-vni later
# associates the VNI with its tenant VRF. Without that replay, the MAC is
# absent from "show evpn mac" and local MAC/IP neighbors remain inactive.

. "$(dirname "$0")/_init_frr.sh"

create_interface p0
set_ip_address p0 172.16.0.2/24

create_vrf tenant
grcli interface add bridge br100 vrf tenant
set_ip_address br100 10.0.0.1/24

# Create the access port and learn its MAC before creating the VXLAN interface.
create_interface p1 domain br100
netns_add access-host
move_to_netns x-p1 access-host
ip -n access-host addr add 10.0.0.2/24 dev x-p1

host_mac=$(ip netns exec access-host cat /sys/class/net/x-p1/address)
ip netns exec access-host ping -c1 -W1 10.0.0.1

attempts=0
while ! grcli -j fdb show iface p1 learn | jq -e --arg mac "$host_mac" \
	'.[] | select(.mac == $mac)' >/dev/null; do
	[ "$attempts" -ge 10 ] && fail "Grout did not learn access MAC $host_mac"
	sleep 0.1
	attempts=$((attempts + 1))
done

# This is intentionally late: the FDB notification above has already been
# delivered while Zebra still knows nothing about VNI 100.
grcli interface add vxlan vxlan100 vni 100 local 172.16.0.2 domain br100

vtysh <<-EOF
configure terminal

vrf tenant
 vni 1000
exit-vrf

router bgp 65000
 bgp router-id 172.16.0.2
 no bgp default ipv4-unicast

 address-family l2vpn evpn
  advertise-all-vni
 exit-address-family
exit
EOF

attempts=0
while ! vtysh -c "show evpn vni 100" | grep -qF "VNI: 100"; do
	[ "$attempts" -ge 50 ] && {
		vtysh -c "show evpn vni"
		fail "FRR did not associate VNI 100"
	}
	sleep 0.1
	attempts=$((attempts + 1))
done

# The local MAC must be replayed into Zebra when the VNI becomes known.
attempts=0
while ! vtysh -c "show evpn mac vni 100" | grep -qiF "$host_mac"; do
	[ "$attempts" -ge 50 ] && {
		grcli fdb show
		vtysh -c "show evpn vni 100"
		vtysh -c "show evpn mac vni 100"
		fail "Zebra lost pre-existing local MAC $host_mac during VNI initialization"
	}
	sleep 0.1
	attempts=$((attempts + 1))
done

vtysh -c "show evpn mac vni 100"
