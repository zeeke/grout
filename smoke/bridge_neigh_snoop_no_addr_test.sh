#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Verify that neigh_snoop learns IPv4 and IPv6 neighbors on a bridge that has
# no IP address of its own (pure L2 stretch, e.g. EVPN L2VNI without anycast
# gateway). A second bridge with addresses is used as a control case.
#
#   .-----------.      .------------------------------.      .-----------.
#   |  host-a   |      |            grout             |      |  host-b   |
#   | 10.0.0.2  |      | +----+   +-------------+ +----+     | 10.0.0.3  |
#   | db8::2    +- - - - + p0 +---+ br0 (no IP) +-+ p1 +- - -+ db8::3    |
#   '-----------'      | +----+   +-------------+ +----+     '-----------'
#   .-----------.      |                              |      .-----------.
#   |  host-c   |      | +----+   +-------------+ +----+     |  host-d   |
#   | 10.0.1.2  +- - - - + p2 +---+ br1 10.0.1.1 +-+ p3 +- - -+ 10.0.1.3  |
#   | db8:1::2  |      | +----+   | db8:1::1    | +----+     | db8:1::3  |
#   '-----------'      |          +-------------+     |      '-----------'
#                      '------------------------------'

. $(dirname $0)/_init.sh

# bridge_case BRIDGE PORT_A PORT_B NS_A NS_B NET4 NET6
bridge_case() {
	local br=$1 pa=$2 pb=$3 nsa=$4 nsb=$5 net4=$6 net6=$7

	port_add $pa domain $br
	port_add $pb domain $br

	netns_add $nsa
	netns_add $nsb
	move_to_netns x-$pa $nsa
	move_to_netns x-$pb $nsb
	ip -n $nsa addr add $net4.2/24 dev x-$pa
	ip -n $nsa addr add $net6::2/64 dev x-$pa nodad
	ip -n $nsb addr add $net4.3/24 dev x-$pb
	ip -n $nsb addr add $net6::3/64 dev x-$pb nodad

	# L2 connectivity through the bridge.
	ip netns exec $nsa ping -i0.01 -c3 -W1 -n $net4.3 || fail "$br: ipv4 L2 ping failed"
	ip netns exec $nsa ping -i0.01 -c3 -W1 -n $net6::3 || fail "$br: ipv6 L2 ping failed"

	# Gratuitous ARP from host A.
	ip netns exec $nsa arping -U -c2 -w3 -I x-$pa $net4.2 || true

	# Unsolicited NA (to ff02::1) from host A: Linux sends one after DAD
	# completes when ndisc_notify is enabled. Re-add the address with DAD.
	ip netns exec $nsa sysctl -wq net.ipv6.conf.x-$pa.ndisc_notify=1
	ip netns exec $nsa sysctl -wq net.ipv6.conf.x-$pa.accept_dad=1
	ip netns exec $nsb timeout 5 tcpdump -c1 -tlpnn -i x-$pb \
		"icmp6 and ip6[40] = 136 and dst host ff02::1" &
	local tcpdump_pid=$!
	sleep 0.5
	ip -n $nsa addr del $net6::2/64 dev x-$pa
	ip -n $nsa addr add $net6::2/64 dev x-$pa
	wait $tcpdump_pid || fail "$br: no unsolicited NA from $nsa seen on $nsb"
}

# expect_neigh BRIDGE NS IFACE ADDR
expect_neigh() {
	local br=$1 ns=$2 dev=$3 addr=$4 mac

	mac=$(ip -n $ns -j link show $dev | jq -r '.[0].address')
	SECONDS=0
	# The MAC is only displayed for reachable neighbors. A freshly learned
	# entry may already have moved to stale/pending by the ageing timer.
	while ! grcli nexthop show | grep -E \
		"\slearn\s+$br\s.*addr=$addr state=(reachable mac=$mac|stale|pending)\s"; do
		if [ "$SECONDS" -gt 5 ]; then
			fail "$br: neighbor $addr ($mac) not learned by neigh_snoop"
			return 1
		fi
		sleep 0.2
	done
}

grcli interface add bridge br0 neigh_suppress on neigh_snoop on
grcli interface add bridge br1 neigh_suppress on neigh_snoop on
grcli address add 10.0.1.1/24 iface br1
grcli address add 2001:db8:1::1/64 iface br1

res=0

# Control: a bridge with IPv4 and IPv6 addresses learns its neighbors.
bridge_case br1 p2 p3 host-c host-d 10.0.1 2001:db8:1
expect_neigh br1 host-c x-p2 10.0.1.2 || res=1
expect_neigh br1 host-c x-p2 2001:db8:1::2 || res=1

# A bridge without any address must learn them too.
bridge_case br0 p0 p1 host-a host-b 10.0.0 2001:db8
expect_neigh br0 host-a x-p0 10.0.0.2 || res=1
expect_neigh br0 host-a x-p0 2001:db8::2 || res=1

grcli address show
grcli nexthop show
[ "$res" = 0 ] || fail "neigh_snoop failed to learn some neighbors"
