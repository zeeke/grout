#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause

# A floating IP (VIP) moves from a host behind a remote VTEP to a host
# attached to a local grout bridge member, which announces it with a
# gratuitous ARP (what keepalived does). Grout must learn the VIP as local and
# FRR must advertise it, superseding the remote EVPN Type-2 MAC+IP route.
#
#     .------------------.                 .------------------.
#     |    evpn-peer     |  <--- BGP --->  |      grout       |
#     | br100 + vxlan100 |    underlay     | br100 + vxlan100 |
#     |    10.0.0.4      |                 |     10.0.0.1     |
#     '--------+---------'  172.16.0.0/24  '--------+---------'
#              |                                    |
#     .--------+---------.                 .--------+---------.
#     |      host-a      |                 |      host-b      |
#     |    10.0.0.2      |    VIP moves    |    10.0.0.3      |
#     |    10.0.0.10  ---------------------->   10.0.0.10     |
#     '------------------'                 '------------------'

. $(dirname $0)/_init_frr.sh

vip=10.0.0.10
mac_a=02:00:00:00:00:02
mac_b=02:00:00:00:00:03

create_interface p0
set_ip_address p0 172.16.0.2/24

start_frr evpn-peer 0

move_to_netns x-p0 evpn-peer
ip -n evpn-peer addr add 172.16.0.1/24 dev x-p0

ip -n evpn-peer link add br100 type bridge
ip -n evpn-peer link set br100 up
# linux needs an IP address in order to learn neighbors
ip -n evpn-peer addr add 10.0.0.4/24 dev br100

ip -n evpn-peer link add vxlan100 type vxlan id 100 local 172.16.0.1 dstport 4789 nolearning
ip -n evpn-peer link set vxlan100 master br100
ip -n evpn-peer link set vxlan100 type bridge_slave neigh_suppress on learning off
ip -n evpn-peer link set vxlan100 up

ip -n evpn-peer link add p1 type veth peer name x-p1
ip -n evpn-peer link set p1 master br100
ip -n evpn-peer link set p1 up

netns_add host-a
ip -n evpn-peer link set x-p1 netns host-a
ip -n host-a link set x-p1 address $mac_a up
ip -n host-a addr add 10.0.0.2/24 dev x-p1

# bgp_evpn <self> <peer> [<vtysh args>...]
bgp_evpn() {
	local self="$1" peer="$2"
	shift 2
	vtysh "$@" <<-EOF
	configure terminal
	router bgp 65000
	 bgp router-id $self
	 no bgp default ipv4-unicast
	 neighbor $peer remote-as 65000
	 address-family l2vpn evpn
	  neighbor $peer activate
	  advertise-all-vni
	  advertise-svi-ip
	 exit-address-family
	exit
	EOF
}
bgp_evpn 172.16.0.1 172.16.0.2 -N evpn-peer
bgp_evpn 172.16.0.2 172.16.0.1

attempts=0
while ! vtysh -c "show evpn" | grep -q "L2 VNIs"; do
	[ "$attempts" -ge 10 ] && fail "EVPN not enabled in zebra"
	sleep 1
	attempts=$((attempts + 1))
done

grcli interface add bridge br100 neigh_suppress on neigh_snoop on
grcli address add 10.0.0.1/24 iface br100
grcli interface add vxlan vxlan100 vni 100 local 172.16.0.2 domain br100

attempts=0
while ! vtysh -c "show evpn vni 100" | grep -q "VNI: 100"; do
	[ "$attempts" -ge 10 ] && fail "zebra did not learn VNI 100"
	sleep 1
	attempts=$((attempts + 1))
done

mark_events
create_interface p1 domain br100
netns_add host-b
move_to_netns x-p1 host-b
ip -n host-b link set x-p1 address $mac_b
ip -n host-b addr add 10.0.0.3/24 dev x-p1

wait_event -t 10 "flood add:.*172.16.0.1.*vni=100"

# -- VIP on host-a, behind the remote VTEP -------------------------------------
ip -n host-a addr add $vip/32 dev x-p1
# Make evpn-peer learn the VIP neighbor and advertise a Type-2 MAC+IP route.
mark_events
ip netns exec host-a ping -c1 -W1 -I $vip 10.0.0.4

# Grout must hold the VIP as a remote nexthop before the move.
wait_event -t 10 "nh new:.*addr=$vip .*mac=$mac_a flags=remote"

# Host b can reach the VIP on host-a
ip netns exec host-b ping -i0.1 -c3 -W1 $vip

# -- VIP moves to host-b, behind grout -----------------------------------------
ip -n host-a addr del $vip/32 dev x-p1
ip -n host-b addr add $vip/32 dev x-p1
# Gratuitous ARP requests (sender IP == target IP), like keepalived sends.
ip netns exec host-b arping -U -c5 -I x-p1 $vip

ip netns exec host-a ping -i0.1 -c3 -W1 $vip || true
sleep 120

# -- Traffic to the VIP reaches its new owner ----------------------------------
ip netns exec host-a ping -i0.1 -c3 -W1 $vip || fail "host-a cannot ping $vip"
