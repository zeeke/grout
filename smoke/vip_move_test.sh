#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause

# Floating IPs (VIPs) move from host-a to host-b. Two VTEPs are emulated with
# two bridges in two VRFs, joined by a wire between two grout ports (u0, u1)
# that stands for the VXLAN tunnel. br-a learned the VIPs from host-a. br-b
# holds them as remote nexthops pointing to host-a's MAC, like an EVPN Type-2
# MAC+IP route would install.
#
#   .-------------------------- grout --------------------------.
#   |  vrf-a                                           vrf-b    |
#   |  br-a 10.0.0.1 (neigh_suppress)         br-b (neigh_suppress)
#   |   p0         u0                        u1         p1      |
#   '---+----------+--------------------------+---------+-------'
#       |          '---------- wire ----------'         |
#    host-a                                          host-b
#    10.0.0.2                                        10.0.0.3
#    10.0.0.10  ---- moves with a gratuitous ARP -->  10.0.0.10
#    10.0.0.11  ---- moves silently --------------->  10.0.0.11

. $(dirname $0)/_init.sh

vip_garp=10.0.0.10
vip_silent=10.0.0.11
mac_a=02:00:00:00:00:02
mac_b=02:00:00:00:00:03

grcli nexthop config set lifetime 2 unreachable 1 ucast-probes 1 bcast-probes 1

grcli interface add vrf vrf-a
grcli interface add vrf vrf-b
grcli interface add bridge br-a vrf vrf-a neigh_suppress on
grcli interface add bridge br-b vrf vrf-b neigh_suppress on
grcli address add 10.0.0.1/24 iface br-a

port_add u0 domain br-a
port_add u1 domain br-b
netns_add wire
move_to_netns x-u0 wire
move_to_netns x-u1 wire
ip -n wire link add br0 type bridge
ip -n wire link set br0 up
ip -n wire link set x-u0 master br0
ip -n wire link set x-u1 master br0

port_add p0 domain br-a
netns_add host-a
move_to_netns x-p0 host-a
ip -n host-a link set x-p0 address $mac_a
ip -n host-a addr add 10.0.0.2/24 dev x-p0
ip -n host-a addr add $vip_garp/32 dev x-p0
ip -n host-a addr add $vip_silent/32 dev x-p0

port_add p1 domain br-b
netns_add host-b
move_to_netns x-p1 host-b
ip -n host-b link set x-p1 address $mac_b
ip -n host-b addr add 10.0.0.3/24 dev x-p1

grcli nexthop add l3 iface br-b address $vip_garp mac $mac_a remote
grcli nexthop add l3 iface br-b address $vip_silent mac $mac_a remote

# br-a learns both VIPs from host-a's ARP requests.
ip netns exec host-a arping -c1 -w1 -I x-p0 -s $vip_garp 10.0.0.1
ip netns exec host-a arping -c1 -w1 -I x-p0 -s $vip_silent 10.0.0.1

# wait_br_a_mac <ip> <mac>: wait until br-a's nexthop for <ip> is reachable
# with <mac>.
wait_br_a_mac() {
	local ip="$1" mac="$2" attempts=0
	while ! grcli nexthop show vrf vrf-a | grep -q "addr=$ip state=reachable mac=$mac"; do
		if [ "$attempts" -ge 30 ]; then
			grcli nexthop show
			fail "br-a: $ip is not reachable with mac $mac"
		fi
		sleep 0.2
		attempts=$((attempts + 1))
	done
}

# -- VIPs move to host-b -------------------------------------------------------
ip -n host-a addr del $vip_garp/32 dev x-p0
ip -n host-a addr del $vip_silent/32 dev x-p0
ip -n host-b addr add $vip_garp/32 dev x-p1
ip -n host-b addr add $vip_silent/32 dev x-p1
# Gratuitous ARP requests (sender IP == target IP), like keepalived sends.
ip netns exec host-b arping -U -c2 -w3 -I x-p1 $vip_garp

# br-b must flood the gratuitous ARP instead of answering it from its remote
# nexthop, so that br-a learns the new owner.
wait_br_a_mac $vip_garp $mac_b

# When br-a's entry ages out, its broadcast probe must not be answered by br-b
# from the stale remote nexthop, so that br-a learns the new owner.
wait_br_a_mac $vip_silent $mac_b
