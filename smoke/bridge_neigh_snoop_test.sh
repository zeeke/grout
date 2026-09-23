#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Verify that neigh_snoop learns IPv4 neighbors from gratuitous ARP on a
# bridge with no IPv4 address.
#
#   .-------------.      .----------------------.      .-------------.
#   |   host-a    |      |        grout         |      |   host-b    |
#   | 10.0.0.2   |      |  br0 (no IPv4 addr)  |      | 10.0.0.3   |
#   | +--------+  |      |  +----+        +----+ |      | +--------+  |
#   | | x-p0   +--+------+--+ p0 +--br0---+ p1 +--+------+ x-p1 |  |
#   | +--------+  |      |  +----+        +----+ |      | +--------+  |
#   '-------------'      '----------------------'      '-------------'

. "$(dirname "$0")/_init.sh"

grcli interface add bridge br0 neigh_snoop on
port_add p0 domain br0
port_add p1 domain br0

netns_add host-a
move_to_netns x-p0 host-a
ip -n host-a addr add 10.0.0.2/24 dev x-p0

netns_add host-b
move_to_netns x-p1 host-b
ip -n host-b addr add 10.0.0.3/24 dev x-p1

mac_a=$(ip -j -n host-a link show dev x-p0 | jq -er '.[0].address')
mac_b=$(ip -j -n host-b link show dev x-p1 | jq -er '.[0].address')

dump_fail() {
	grcli nexthop show || :
	grcli stats show software || :
	[ -s "$tmp/arping.out" ] && cat "$tmp/arping.out" >&2
	fail "$*"
}

send_garp() {
	local ns=$1 mode=$2 dev=$3 ip=$4
	ip netns exec "$ns" arping "$mode" -c1 -w1 -I "$dev" "$ip" \
		>"$tmp/arping.out" 2>&1 || :
}

check_garp() {
	local ns=$1 mode=$2 dev=$3 ip=$4 mac=$5
	mark_events
	send_garp "$ns" "$mode" "$dev" "$ip"
	wait_event -t 5 "nh new:.*iface=br0.*origin=learn.*addr=${ip//./\\.}.*mac=$mac" ||
		dump_fail "neigh_snoop did not learn $ip with MAC $mac"
	grcli -j nexthop show type l3 | jq -e --arg ip "$ip" \
		'any(.[]; .origin == "learn" and .iface == "br0" and .addr == $ip)' >/dev/null ||
		dump_fail "No learned neighbor for $ip on br0"
}

# Both gratuitous ARP request and reply forms should teach the bridge.
check_garp host-a -U x-p0 10.0.0.2 "$mac_a"
check_garp host-b -A x-p1 10.0.0.3 "$mac_b"
