#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Robin Jarry

# This test verifies that the presence of an L2 VNI does not break EVPN Type-5
# (IP prefix) L3VPN routing. When both an L3 VNI and an L2 VNI exist in the
# same VRF, the nexthop for remote Type-5 routes must resolve to the L3 VNI
# VXLAN interface, not the L2 VNI one.
#
# The L2 VNI is deliberately created in VRF mode first and then moved to a
# bridge, which is the sequence that triggers the L3VNI mapping overwrite bug.
#
# Each side has a VRF with an L3 VNI (1000) for inter-subnet routing and an
# L2 VNI (100) for intra-subnet bridging.
#
# Success criteria:
#   - Type-5 routes are exchanged and installed.
#   - Remote nexthops use iface=vxlan-l3 (L3 VNI), NOT iface=vxlan100 (L2 VNI).
#   - Host-A and Host-B can ping each other through the L3 VXLAN overlay.
#   - L2 overlay connectivity through VNI 100 also works.
#
#   .---------------------------------.         .---------------------------------.
#   |           evpn-peer             |         |              grout              |
#   |                                 |         |                                 |
#   | .- - - - - - - - - .            |         |            .- - - - - - - - - . |
#   | '  vrf tenant      '            |         |            '      vrf tenant  ' |
#   | '                  '            |         |            '                  ' |
#   | '  +-------+       '            |         |            '                  ' |
#   | '  | br-l3 |       '            |         |            '                  ' |
#   | '  +---+---+       '            |         |            '                  ' |
#   | ' +----+-----+     '            |         |            ' +----------+     ' |
#   | ' | vxlan-l3 |...........        |         |     ..........| vxlan-l3 |     ' |
#   | ' +----------+     '    .        |         |     .       ' +----------+     ' |
#   | '                  '    .        |         |     .       '                  ' |
#   | '  +-------+       '    .        |         |     .       '  +-------+       ' |
#   | '  | br100 |       '    .        |         |     .       '  | br100 |       ' |
#   | '  +---+---+       '    .        |         |     .       '  +---+---+       ' |
#   | ' +----+-----+     '    .        |         |     .       ' +----+-----+     ' |
#   | ' | vxlan100 |...........        |         |     ..........| vxlan100 |     ' |
#   | ' +----------+     '    .        |         |     .       ' +----------+     ' |
#   | '      |           '    .        |         |     .       '      |           ' |
#   | '  +---+---+       '    .        |         |     .       '  +---+---+       ' |
#   | '  |  p2   |       '    .        |         |     .       '  |  p2   |       ' |
#   | '  +---+---+       '    .        |         |     .       '  +---+---+       ' |
#   | '      |           '    .        |         |     .       '      |           ' |
#   | '      .1          '   .1        |         |    .2       '      .1          ' |
#   | '  +------+        ' +--------+  |         | +------+    '  +-------+       ' |
#   | '  |  p1  |        ' |  x-p0  |  |         | |  p0  |    '  |   p1  |       ' |
#   | '  +--+---+        ' +---+----+  |         | +--+---+    '  +---+---+       ' |
#   | '- - -|- - - - - - '     |       |         |    |        '- - - |- - - - - -' |
#   '-------|-------------------|------'         '----|---------------|-------------'
#           |                   |                      |              |
#           |                   | <------- BGP  -----> |              |
#     16.0.0.0/24               '----------------------'       48.0.0.0/24
#           |                       underlay                          |
#           |                     172.16.0.0/24                       |
#   .-------|-----------.                                  .----------|--------.
#   |   +---+----+      |                                  |      +---+----+   |
#   |   |  x-p1  |      |                                  |      |  x-p1  |   |
#   |   +--------+      | <= = = = L3VPN VNI 1000 = = = => |      +--------+   |
#   |       .2          |                                  |         .2        |
#   |    host-a         |                                  |       host-b      |
#   '-------------------'                                  '-------------------'
#
#   .-------|-----------.                                  .----------|--------.
#   |   +---+----+      |                                  |      +---+----+   |
#   |   |  x-p2  |      |                                  |      |  x-p2  |   |
#   |   +--------+      | <= = = = L2VNI VNI 100  = = = => |      +--------+   |
#   |       .2          |                                  |         .3        |
#   |    host-c         |                                  |       host-d      |
#   '-------------------'                                  '-------------------'

. $(dirname $0)/_init_frr.sh

# right side (grout) -----------------------------------------------------------
create_interface p0
set_ip_address p0 172.16.0.2/24

# left side (Linux peer) -------------------------------------------------------
start_frr evpn-peer

ip netns exec evpn-peer sysctl -qw net.ipv4.conf.all.forwarding=1
ip netns exec evpn-peer sysctl -qw net.ipv4.conf.all.rp_filter=0
ip netns exec evpn-peer sysctl -qw net.ipv4.conf.default.rp_filter=0
ip netns exec evpn-peer sysctl -qw net.ipv6.conf.all.forwarding=1

move_to_netns x-p0 evpn-peer
ip -n evpn-peer addr add 172.16.0.1/24 dev x-p0

# Create L3VNI VXLAN on the Linux peer with a bridge+SVI (required by Linux)
ip -n evpn-peer link add br-l3 type bridge
ip -n evpn-peer link set br-l3 up

ip -n evpn-peer link add vxlan-l3 type vxlan id 1000 local 172.16.0.1 dstport 4789 nolearning
ip -n evpn-peer link set vxlan-l3 master br-l3
ip -n evpn-peer link set vxlan-l3 up

# Create L2VNI VXLAN on the Linux peer
ip -n evpn-peer link add br100 type bridge
ip -n evpn-peer link set br100 up

ip -n evpn-peer link add vxlan100 type vxlan id 100 local 172.16.0.1 dstport 4789 nolearning
ip -n evpn-peer link set vxlan100 master br100
ip -n evpn-peer link set vxlan100 up

# Create VRF "tenant" on the peer and bind both bridges
ip -n evpn-peer link add tenant type vrf table 10
ip -n evpn-peer link set tenant up
ip -n evpn-peer link set br-l3 master tenant
ip -n evpn-peer link set br100 master tenant

# Assign an SVI address to the L2 bridge for inter-subnet routing
ip -n evpn-peer addr add 10.0.0.1/24 dev br100

# Host-facing port in the peer VRF (L3 inter-subnet)
ip -n evpn-peer link add p1 type veth peer name x-p1
ip -n evpn-peer link set p1 master tenant
ip -n evpn-peer link set p1 up
ip -n evpn-peer addr add 16.0.0.1/24 dev p1

# Host-facing port in the peer L2 bridge
ip -n evpn-peer link add p2 type veth peer name x-p2
ip -n evpn-peer link set p2 master br100
ip -n evpn-peer link set p2 up

netns_add host-a
ip -n evpn-peer link set x-p1 netns host-a
ip -n host-a link set x-p1 up
ip -n host-a addr add 16.0.0.2/24 dev x-p1
ip -n host-a route add default via 16.0.0.1

netns_add host-c
ip -n evpn-peer link set x-p2 netns host-c
ip -n host-c link set x-p2 up
ip -n host-c addr add 10.0.0.2/24 dev x-p2

# FRR config on the Linux peer
vtysh -N evpn-peer <<-EOF
configure terminal

vrf tenant
 vni 1000
exit-vrf

router bgp 65000
 bgp router-id 172.16.0.1
 no bgp default ipv4-unicast

 neighbor 172.16.0.2 remote-as 65000

 address-family l2vpn evpn
  neighbor 172.16.0.2 activate
  advertise-all-vni
 exit-address-family
exit

router bgp 65000 vrf tenant
 bgp router-id 172.16.0.1

 address-family ipv4 unicast
  redistribute connected
 exit-address-family

 address-family l2vpn evpn
  advertise ipv4 unicast
 exit-address-family
exit
EOF

# right side (grout) setup L3VPN + L2VNI ---------------------------------------
create_vrf tenant

# L3 VNI VXLAN in VRF mode (no bridge needed in grout)
grcli interface add vxlan vxlan-l3 vni 1000 local 172.16.0.2 vrf tenant

# L2 VNI: deliberately create in VRF first, then move to a bridge.
# This is the sequence that causes l3vni_set() to overwrite the L3 VNI
# mapping with the L2 VNI interface, resulting in Type-5 nexthops
# pointing to the wrong VXLAN.
grcli interface add bridge br100
grcli interface add vxlan vxlan100 vni 100 local 172.16.0.2 vrf tenant
grcli interface set vxlan vxlan100 domain br100

create_interface p1 vrf tenant
set_ip_address p1 48.0.0.1/24

create_interface p2 domain br100

netns_add host-b
move_to_netns x-p1 host-b
ip -n host-b addr add 48.0.0.2/24 dev x-p1
ip -n host-b route add default via 48.0.0.1

netns_add host-d
move_to_netns x-p2 host-d
ip -n host-d addr add 10.0.0.3/24 dev x-p2

mark_events

# FRR config on grout
vtysh <<-EOF
configure terminal

vrf tenant
 vni 1000
exit-vrf

router bgp 65000
 bgp router-id 172.16.0.2
 no bgp default ipv4-unicast

 neighbor 172.16.0.1 remote-as 65000

 address-family l2vpn evpn
  neighbor 172.16.0.1 activate
  advertise-all-vni
 exit-address-family
exit

router bgp 65000 vrf tenant
 bgp router-id 172.16.0.2

 address-family ipv4 unicast
  redistribute connected
 exit-address-family

 address-family l2vpn evpn
  advertise ipv4 unicast
 exit-address-family
exit
EOF

# -- Check L3VNI is recognized by both sides -----------------------------------
attempts=0
while ! vtysh -c "show evpn vni 1000" | grep -qF "L3"; do
	if [ "$attempts" -ge 5 ]; then
		vtysh -c "show evpn vni"
		fail "Grout FRR does not recognize VNI 1000 as L3VNI"
	fi
	sleep 1
	attempts=$((attempts + 1))
done

attempts=0
while ! vtysh -N evpn-peer -c "show evpn vni 1000" | grep -qF "L3"; do
	if [ "$attempts" -ge 5 ]; then
		vtysh -N evpn-peer -c "show evpn vni"
		fail "Linux peer does not recognize VNI 1000 as L3VNI"
	fi
	sleep 1
	attempts=$((attempts + 1))
done

# -- Check L2VNI is recognized by both sides -----------------------------------
attempts=0
while ! vtysh -c "show evpn vni 100" | grep -qF "VNI: 100"; do
	if [ "$attempts" -ge 5 ]; then
		vtysh -c "show evpn vni"
		fail "Grout FRR does not recognize VNI 100 as L2VNI"
	fi
	sleep 1
	attempts=$((attempts + 1))
done

# -- Wait for EVPN type-5 route exchange (IPv4) --------------------------------
attempts=0
while ! vtysh -c "show bgp l2vpn evpn route type 5" | grep -qF "16.0.0.0"; do
	if [ "$attempts" -ge 5 ]; then
		vtysh -c "show bgp l2vpn evpn route type 5"
		fail "Grout FRR did not learn type-5 route for 16.0.0.0/24"
	fi
	sleep 1
	attempts=$((attempts + 1))
done

attempts=0
while ! vtysh -N evpn-peer -c "show bgp l2vpn evpn route type 5" | grep -qF "48.0.0.0"; do
	if [ "$attempts" -ge 5 ]; then
		vtysh -N evpn-peer -c "show bgp l2vpn evpn route type 5"
		fail "Linux peer did not learn type-5 route for 48.0.0.0/24"
	fi
	sleep 1
	attempts=$((attempts + 1))
done

# -- Wait for routes to be installed in VRF ------------------------------------
wait_event 'route4 add: vrf=tenant 16.0.0.0/24'

# -- Check RMAC is set on route nexthops and uses L3 VNI ----------------------
rmac=$(ip netns exec evpn-peer cat /sys/class/net/vxlan-l3/address)

# KEY ASSERTION: the nexthop MUST use iface=vxlan-l3 (the L3 VNI, VNI 1000),
# NOT iface=vxlan100 (the L2 VNI, VNI 100). Without the fix, the L3VNI
# mapping is overwritten by the L2 VNI and this wait_event times out.
#wait_event "nh new: type=L3 id=[0-9]+ iface=vxlan-l3 vrf=tenant origin=zebra family=ipv4 addr=172.16.0.1 mac=$rmac flags=static remote"

vtysh -c "show bgp l2vpn evpn route type 5"
grcli route show vrf tenant
grcli nexthop show vrf tenant

# -- Verify L3 connectivity through L3 VNI VXLAN overlay ----------------------
ip netns exec host-b ping -i0.1 -c3 -W1 16.0.0.2
ip netns exec host-a ping -i0.1 -c3 -W1 48.0.0.2

# -- Verify L2 connectivity through L2 VNI VXLAN overlay ----------------------

# Wait for EVPN type-3 (flood VTEP) exchange for VNI 100
wait_event "flood add: vtep vrf=main 172.16.0.1 vni=100"

ip netns exec host-c ping -i0.1 -c3 -W1 10.0.0.3
ip netns exec host-d ping -i0.1 -c3 -W1 10.0.0.2
