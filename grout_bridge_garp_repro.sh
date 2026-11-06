#!/bin/bash
# Report how a grout bridge learns neighbors from a gratuitous ARP, with and
# without an IP address on the bridge, for each neigh_snoop value.
# Same matrix as kernel_bridge_garp_repro.sh (neigh_snoop instead of arp_accept).
#
# Usage: sudo ./grout_bridge_garp_repro.sh [IMAGE...]
#
# Topology: host-a (x-p0, 10.0.0.2/24) --tap-- p0 [br0] in grout

IMAGES=("$@")
[ $# -eq 0 ] && IMAGES=(quay.io/grout/grout:0.19.3 quay.io/grout/grout:0.20.0)
NAME=grout-garp

cleanup() {
	podman rm -f $NAME >/dev/null 2>&1
	ip netns del gr-garp 2>/dev/null
	ip netns del gr-garp-host 2>/dev/null
}
trap cleanup EXIT

grcli() { podman exec $NAME grcli "$@"; }

run_case() {
	local image=$1 snoop=$2 addr=$3 learned

	cleanup
	ip netns add gr-garp
	ip netns add gr-garp-host
	podman run -d --rm --name $NAME --privileged \
		--network ns:/run/netns/gr-garp $image /usr/bin/grout -t >/dev/null
	for i in $(seq 50); do grcli interface show >/dev/null 2>&1 && break; sleep 0.2; done

	grcli interface add bridge br0 neigh_suppress on neigh_snoop $snoop >/dev/null
	[ -n "$addr" ] && grcli address add $addr iface br0
	grcli interface add port p0 devargs net_tap0,iface=x-p0 domain br0 >/dev/null

	ip -n gr-garp link set x-p0 netns gr-garp-host
	ip -n gr-garp-host link set x-p0 address 02:00:00:00:00:02 up
	ip -n gr-garp-host addr add 10.0.0.2/24 dev x-p0
	sleep 1

	ip netns exec gr-garp-host arping -q -U -c2 -I x-p0 10.0.0.2
	sleep 1

	learned=$(grcli nexthop show | grep -E "\sbr0\s.*addr=10\.0\.0\.2 " |
		sed -E 's/.*(addr=.*)/\1/')
	printf '%-8s %-12s %-14s %s\n' "${image##*:}" "$snoop" "${addr:-none}" \
		"${learned:-NOT LEARNED}"
}

printf '%-8s %-12s %-14s %s\n' GROUT NEIGH_SNOOP BR0_ADDR "grcli nexthop show (br0 10.0.0.2)"
for image in "${IMAGES[@]}"; do
	for addr in "" 10.0.0.1/24 192.168.0.1/24; do
		for snoop in off on; do
			run_case $image $snoop "$addr"
		done
	done
done
