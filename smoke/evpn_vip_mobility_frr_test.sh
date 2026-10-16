#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Verify that a learned EVPN neighbor is withdrawn once it stops answering.
#
# host-b sits behind grout. Its IP+MAC is learned by grout (neigh_snoop),
# reported to zebra as a local neighbor and advertised as a Type-2 MAC+IP
# route to evpn-peer.
#
# host-b then silently drops its address, like a keepalived VIP moving
# to another node. The grout nexthop must age out (reachable -> stale ->
# probes -> failed), be removed, and zebra must withdraw the Type-2 route
# so that evpn-peer no longer has a remote neighbor for the old binding.
#
#     .-------------------------.          .-------------------------.
#     |       evpn-peer         |          |         grout           |
#     |                         |          |                         |
#     | +----------+            |          |            +----------+ |
#     | | vxlan100 |            |          |            | vxlan100 | |
#     | +----+-----+            |          |            +-----+----+ |
#     |      |                  |          |                  |      |
#     |  +---+---+              |          |              +---+---+  |
#     |  | br100 |              |          |              | br100 |  |
#     |  +---+---+              |          |              +---+---+  |
#     |      |           .1     |          |     .2           |      |
#     |  +---+---+    +-------+ |          | +------+     +---+---+  |
#     |  |   p1  |    | x-p0  | |          | |  p0  |     |   p1  |  |
#     |  +---+---+    +---+---+ |          | +---+--+     +---+---+  |
#     '------|------------|-----'          '-----|------------|------'
#            |            |                      |            |
#            |            |  <----- BGP ----->   |            |
#     .------|--------.   `----------------------'    .-------|------.
#     |  +---+----+   |           underlay            |   +---+----+ |
#     |  |  x-p1  |   |         172.16.0.0/24         |   |  x-p1  | |
#     |  +--------+   |                               |   +--------+ |
#     |      .2       |                               |       .3     |
#     |    host-a     |           overlay             |    host-b    |
#     '---------------'         10.0.0.0/24           '--------------'

. $(dirname $0)/_init_frr.sh

# right side -------------------------------------------------------------------
create_interface p0
set_ip_address p0 172.16.0.2/24

# left side --------------------------------------------------------------------
start_frr evpn-peer 0

ip netns exec evpn-peer sysctl -qw net.ipv4.conf.all.forwarding=1
ip netns exec evpn-peer sysctl -qw net.ipv4.conf.all.rp_filter=0
ip netns exec evpn-peer sysctl -qw net.ipv4.conf.default.rp_filter=0

move_to_netns x-p0 evpn-peer
ip -n evpn-peer addr add 172.16.0.1/24 dev x-p0

ip -n evpn-peer link add br100 type bridge
ip -n evpn-peer link set br100 up
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
ip -n host-a link set x-p1 up
ip -n host-a addr add 10.0.0.2/24 dev x-p1

for ns in evpn-peer ""; do
	if [ -n "$ns" ]; then
		router_id=172.16.0.1
		neighbor=172.16.0.2
	else
		router_id=172.16.0.2
		neighbor=172.16.0.1
	fi
	vtysh ${ns:+-N $ns} <<-EOF
	configure terminal

	router bgp 65000
	 bgp router-id $router_id
	 no bgp default ipv4-unicast

	 neighbor $neighbor remote-as 65000

	 address-family l2vpn evpn
	  neighbor $neighbor activate
	  advertise-all-vni
	  advertise-svi-ip
	 exit-address-family
	exit
	EOF
done

attempts=0
while ! vtysh -c "show evpn" | grep -q "L2 VNIs"; do
	if [ "$attempts" -ge 10 ]; then
		vtysh -c "show evpn"
		fail "EVPN not enabled in zebra"
	fi
	sleep 1
	attempts=$((attempts + 1))
done

# Short lifetimes so that the test does not take 20 minutes.
grcli nexthop config set lifetime 2 unreachable 1 ucast-probes 1 bcast-probes 1

grcli interface add bridge br100 neigh_suppress on neigh_snoop on
grcli address add 10.0.0.1/24 iface br100
grcli interface add vxlan vxlan100 vni 100 local 172.16.0.2 domain br100

attempts=0
while ! vtysh -c "show evpn vni 100" | grep -q "VNI: 100"; do
	if [ "$attempts" -ge 10 ]; then
		vtysh -c "show evpn vni 100"
		fail "zebra did not learn VNI 100"
	fi
	sleep 1
	attempts=$((attempts + 1))
done

mark_events
create_interface p1 domain br100

netns_add host-b
move_to_netns x-p1 host-b
ip -n host-b addr add 10.0.0.3/24 dev x-p1

wait_event -t 10 "flood add:.*172.16.0.1.*vni=100"

# -- Learn host-b on grout and advertise it to evpn-peer ----------------------
ip netns exec host-b ping -c1 -W1 10.0.0.1
ip netns exec host-a ping -i0.1 -c3 -W1 10.0.0.3

dump_state() {
	grcli nexthop show
	vtysh -c "show evpn arp-cache vni 100"
	vtysh -N evpn-peer -c "show evpn arp-cache vni 100"
	ip -n evpn-peer neigh show dev br100
}

# poll <timeout_sec> <command...>: retry command every 0.5s until it succeeds
poll() {
	local deadline=$((SECONDS + $1))
	shift
	while ! "$@" >/dev/null 2>&1; do
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 0.5
	done
}

grout_nh_state() {
	grcli -j nexthop show type l3 | jq -e --arg s "$1" \
		'.[] | select(.addr == "10.0.0.3" and .origin == "learn" and .state == $s)'
}

grout_nh_absent() {
	! grcli -j nexthop show type l3 | jq -e '.[] | select(.addr == "10.0.0.3" and .origin == "learn")'
}

zebra_has() {
	vtysh ${2:+-N $2} -c 'show evpn arp-cache vni 100 json' |
		jq -e --arg t "$1" '."10.0.0.3" | select(.type == $t)'
}

zebra_absent() {
	! vtysh ${1:+-N $1} -c 'show evpn arp-cache vni 100 json' | jq -e '."10.0.0.3"'
}

# With a 2s lifetime the entry cycles reachable/stale while host-b answers
# the probes, only check that it exists.
poll 10 eval '! grout_nh_absent' || { dump_state; fail "grout did not learn 10.0.0.3"; }
poll 10 zebra_has local || { dump_state; fail "zebra did not learn 10.0.0.3 as local"; }
poll 10 zebra_has remote evpn-peer || { dump_state; fail "evpn-peer did not install 10.0.0.3 as remote"; }

# -- host-b silently drops its address ----------------------------------------
# The link stays up and nothing is sent: grout only notices through its own
# nexthop ageing and probing.
ip -n host-b addr del 10.0.0.3/24 dev x-p1

# lifetime (2s) + 2 probes (1s apart) + margin
poll 10 grout_nh_state failed || { dump_state; fail "grout nexthop 10.0.0.3 did not age out to failed"; }
grcli nexthop show

# The failed nexthop must be removed after the unreachable lifetime (1s) and
# zebra must be told so that the Type-2 route is withdrawn.
errors=()
poll 10 grout_nh_absent || errors+=("grout did not remove failed learned nexthop 10.0.0.3")
poll 5 zebra_absent || errors+=("zebra still has 10.0.0.3 in its arp-cache")
poll 5 zebra_absent evpn-peer || errors+=("evpn-peer still has 10.0.0.3 as remote neighbor")

if [ "${#errors[@]}" -gt 0 ]; then
	dump_state
	fail "$(printf '%s; ' "${errors[@]}")"
fi
