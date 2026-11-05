#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Verify that a neighbor snooped on a bridge without any IP address (pure L2
# stretch EVPN L2VNI, no anycast gateway) is exported to zebra as a local
# EVPN ARP cache entry, so that it can be advertised as a Type-2 MAC+IP route.
#
#   .-----------.      .--------------------------------.
#   |  host-a   |      |              grout             |
#   | 10.0.0.2  |      | +----+   +-------------+       |
#   |   x-p0    +- - - - + p0 +---+ br0 (no IP) +--vni100
#   '-----------'      | +----+   +-------------+       |
#                      '--------------------------------'

. $(dirname $0)/_init_frr.sh

vtysh <<-EOF
configure terminal
router bgp 65000
 bgp router-id 172.16.0.1
 no bgp default ipv4-unicast
 address-family l2vpn evpn
  advertise-all-vni
 exit-address-family
exit
EOF

attempts=0
while ! vtysh -c "show evpn" | grep -q "L2 VNIs"; do
	[ "$attempts" -ge 10 ] && fail "EVPN not enabled in zebra"
	sleep 1
	attempts=$((attempts + 1))
done

grcli interface add bridge br0 neigh_suppress on neigh_snoop on
grcli interface add vxlan vni100 vni 100 local 172.16.0.1 domain br0

attempts=0
while ! vtysh -c "show evpn vni 100" | grep -q "VNI: 100"; do
	[ "$attempts" -ge 10 ] && fail "zebra did not learn VNI 100"
	sleep 1
	attempts=$((attempts + 1))
done

create_interface p0 domain br0
netns_add host-a
move_to_netns x-p0 host-a
ip -n host-a addr add 10.0.0.2/24 dev x-p0
mac=$(ip -n host-a -j link show x-p0 | jq -r '.[0].address')

ip netns exec host-a arping -U -c2 -w3 -I x-p0 10.0.0.2 || true

attempts=0
while ! vtysh -c 'show evpn arp-cache vni 100 json' |
	jq -e --arg mac "$mac" '."10.0.0.2" |
		select(.type == "local" and (.mac | ascii_downcase) == $mac)'; do
	if [ "$attempts" -ge 10 ]; then
		grcli nexthop show
		vtysh -c 'show evpn vni 100'
		vtysh -c 'show evpn arp-cache vni 100'
		fail "10.0.0.2 ($mac) not in zebra EVPN ARP cache as local"
	fi
	sleep 1
	attempts=$((attempts + 1))
done
