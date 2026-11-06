#!/bin/bash
# Report how a Linux kernel bridge learns neighbors from a gratuitous ARP,
# with and without an IP address on the bridge, for each arp_accept value.
#
# Usage: sudo ./kernel_bridge_garp_repro.sh
#
# Topology: host-a (x-p0, 10.0.0.2/24) --veth-- p0 [br0] in netns kbr

cleanup() {
	ip netns del kbr 2>/dev/null
	ip netns del kbr-host 2>/dev/null
}
trap cleanup EXIT

run_case() {
	local arp_accept=$1 addr=$2 learned

	cleanup
	ip netns add kbr
	ip netns add kbr-host
	# Bring lo up as in any real netns: with no IPv4 address at all in the
	# netns, the kernel never learns from a gratuitous ARP.
	ip -n kbr link set lo up
	ip -n kbr link add br0 type bridge
	ip -n kbr link add p0 type veth peer name x-p0 netns kbr-host
	ip -n kbr link set p0 master br0 up
	ip -n kbr link set br0 up
	ip netns exec kbr sysctl -qw net.ipv4.conf.all.arp_accept=$arp_accept
	ip netns exec kbr sysctl -qw net.ipv4.conf.br0.arp_accept=$arp_accept
	[ -n "$addr" ] && ip -n kbr addr add $addr dev br0
	ip -n kbr-host link set x-p0 address 02:00:00:00:00:02 up
	ip -n kbr-host addr add 10.0.0.2/24 dev x-p0
	sleep 1 # bridge port forwarding state

	ip netns exec kbr-host arping -q -U -c2 -I x-p0 10.0.0.2
	sleep 0.5

	learned=$(ip -n kbr neigh show dev br0 10.0.0.2)
	printf '%-12s %-14s %s\n' "$arp_accept" "${addr:-none}" "${learned:-NOT LEARNED}"
}

printf '%-12s %-14s %s\n' ARP_ACCEPT BR0_ADDR "ip neigh show dev br0 10.0.0.2"
for addr in "" 10.0.0.1/24 192.168.0.1/24; do
	for arp_accept in 0 1 2; do
		run_case $arp_accept "$addr"
	done
done
