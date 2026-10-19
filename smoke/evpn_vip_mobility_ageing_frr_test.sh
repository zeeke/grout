#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Verify that an EVPN VIP follows its owner when it moves between VTEPs, once
# the old VTEP has aged out its neighbor entry.
#
# A virtual IP is moved between host-a (behind evpn-peer) and host-b (behind
# grout) the way keepalived does it: the old owner silently drops the address
# and the new owner periodically announces it with gratuitous ARPs.
#
# Neither VTEP learns the VIP from gratuitous ARPs while it still has a remote
# entry for it. The old VTEP must first declare its local neighbor failed, so
# that the Type-2 route is withdrawn. evpn-peer is configured the way
# OpenPERouter runs the kernel datapath: arp_accept=1 and a refresher pinging
# STALE neighbors on the bridge. grout probes its learned nexthops by itself
# and reports failed ones to zebra. Both use short ageing timers.
#
# 1. host-a owns the VIP. evpn-peer learns it and advertises a Type-2 MAC+IP
#    route. grout installs it as a remote nexthop.
# 2. The VIP moves to host-b. evpn-peer probes its stale neighbor, zebra
#    withdraws the route, and grout learns the VIP from the next gratuitous
#    ARP. evpn-peer installs it as remote with host-b's MAC.
# 3. The VIP moves back to host-a. grout probes its learned nexthop, reports
#    it failed, zebra withdraws the route, and evpn-peer learns the VIP from
#    the next gratuitous ARP. grout replaces its learned nexthop with the
#    remote one.
#
# Each step also checks that the VIP is reachable through the overlay.
#
#     .-------------------------.          .-------------------------.
#     |       evpn-peer         |          |         grout           |
#     |                         |          |                         |
#     | +----------+            |          |            +----------+ |
#     | | vxlan100 |            |          |            | vxlan100 | |
#     | +----+-----+            |          |            +-----+----+ |
#     |      |                  |          |                  |      |
#     |  +---+---+              |          |              +---+---+  |
#     |  | br100 | .4           |          |           .1 | br100 |  |
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
#                             VIP 10.0.0.10/24

. $(dirname $0)/_init_frr.sh

vip=10.0.0.10

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
# linux needs an IP address in order to learn neighbors
ip -n evpn-peer addr add 10.0.0.4/24 dev br100
# learn neighbors from gratuitous ARPs and age them quickly
ip netns exec evpn-peer sysctl -qw net.ipv4.conf.br100.arp_accept=1
ip netns exec evpn-peer sysctl -qw net.ipv4.neigh.br100.base_reachable_time_ms=2000
ip netns exec evpn-peer sysctl -qw net.ipv4.neigh.br100.delay_first_probe_time=1
# OpenPERouter bridge refresher: ping STALE neighbors so that dead ones go
# PROBE -> FAILED and zebra withdraws their Type-2 route.
ip netns exec evpn-peer sh -c '
	while sleep 1; do
		ip -4 neigh show dev br100 nud stale | while read -r ip _; do
			ping -c1 -W1 -I br100 $ip >/dev/null 2>&1 &
		done
	done' &

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

grcli nexthop config set lifetime 2
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

mac_a=$(ip netns exec host-a cat /sys/class/net/x-p1/address)
mac_b=$(ip netns exec host-b cat /sys/class/net/x-p1/address)

# -- Helpers --------------------------------------------------------------------
dump_state() {
	grcli nexthop show
	vtysh -c "show evpn arp-cache vni 100"
	vtysh -N evpn-peer -c "show evpn arp-cache vni 100"
	vtysh -c "show bgp l2vpn evpn route type macip"
	ip -n evpn-peer -d neigh show $vip
	bridge -n evpn-peer fdb show br br100 master
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

# grout_nh_is <learn|zebra> <mac>: grout has a single nexthop for the VIP with
# the given origin and MAC. Remote nexthops are installed by zebra.
grout_nh_is() {
	grcli -j nexthop show type l3 | jq -e --arg ip $vip --arg o "$1" --arg m "$2" '
		[.[] | select(.addr == $ip)] |
		length == 1 and .[0].origin == $o and .[0].mac == $m'
}

# arp_cache_is <local|remote> <mac> [netns]: zebra EVPN arp-cache entry.
arp_cache_is() {
	vtysh ${3:+-N $3} -c 'show evpn arp-cache vni 100 json' |
		jq -e --arg ip $vip --arg t "$1" --arg m "$2" \
		'.[$ip] | select(.type == $t and .mac == $m and .state == "active")'
}

# reaches <netns> <mac>: <netns> resolves the VIP to <mac> and can ping it.
reaches() {
	ip -n $1 neigh flush dev x-p1
	ip netns exec $1 ping -c1 -W1 $vip >/dev/null || return 1
	ip -n $1 neigh show $vip dev x-p1 | grep -qi "lladdr $2"
}

# check <timeout_sec> <message> <command...>
errors=()
check() {
	local timeout=$1 msg=$2
	shift 2
	poll $timeout "$@" || errors+=("$msg")
}

check_errors() {
	if [ "${#errors[@]}" -gt 0 ]; then
		dump_state
		fail "$(printf '%s; ' "${errors[@]}")"
	fi
}

# vip_add <netns>: take ownership of the VIP like keepalived does, with a
# gratuitous ARP every second (garp_master_refresh).
declare -A garp_pid
vip_add() {
	ip -n $1 addr add $vip/24 dev x-p1
	ip netns exec $1 arping -q -U -i1 -I x-p1 $vip &
	garp_pid[$1]=$!
}

# vip_del <netns>: silently drop the VIP.
vip_del() {
	kill ${garp_pid[$1]}
	wait ${garp_pid[$1]} || :
	ip -n $1 addr del $vip/24 dev x-p1
}

# -- Initial state: host-a owns the VIP ---------------------------------------
vip_add host-a

check 10 "evpn-peer did not learn $vip as local" arp_cache_is local $mac_a evpn-peer
check 10 "zebra did not learn $vip as remote" arp_cache_is remote $mac_a
check 10 "grout did not install $vip as remote" grout_nh_is zebra $mac_a
check 5 "host-b cannot reach $vip on host-a" reaches host-b $mac_a
check_errors

# -- Move the VIP to host-b -----------------------------------------------------
vip_del host-a
vip_add host-b

check 60 "grout did not learn $vip from host-b" grout_nh_is learn $mac_b
check 10 "zebra did not learn $vip as local" arp_cache_is local $mac_b
check 10 "evpn-peer did not install $vip as remote" arp_cache_is remote $mac_b evpn-peer
check 5 "host-a cannot reach $vip on host-b" reaches host-a $mac_b
check_errors

# -- Move the VIP back to host-a ------------------------------------------------
vip_del host-b
vip_add host-a

check 60 "evpn-peer did not learn $vip back as local" arp_cache_is local $mac_a evpn-peer
check 10 "zebra did not learn $vip back as remote" arp_cache_is remote $mac_a
check 10 "grout did not replace learned $vip with remote" grout_nh_is zebra $mac_a
check 5 "host-b cannot reach $vip back on host-a" reaches host-b $mac_a
check_errors
