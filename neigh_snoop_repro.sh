#!/bin/bash
# Reproduce: neigh_snoop does not learn IPv4 neighbors on a bridge without
# an IP address (regression from 3f2f68e8, first released in v0.20.0).
#
# Usage: sudo ./neigh_snoop_repro.sh [IMAGE]
# Expected: PASS on quay.io/grout/grout:0.19.3, FAIL on quay.io/grout/grout:0.20.0

IMAGE=${1:-quay.io/grout/grout:0.20.0}
NAME=grout-repro

cleanup() {
	podman rm -f $NAME >/dev/null 2>&1
	ip netns del gr-repro 2>/dev/null
	ip netns del gr-host 2>/dev/null
}
trap cleanup EXIT
cleanup

set -e
ip netns add gr-repro
ip netns add gr-host

# Run grout in test mode (no hugepages) inside the gr-repro netns.
podman run -d --rm --name $NAME --privileged \
	--network ns:/run/netns/gr-repro $IMAGE /usr/bin/grout -t >/dev/null
grcli() { podman exec $NAME grcli "$@"; }
for i in $(seq 50); do grcli interface show >/dev/null 2>&1 && break; sleep 0.2; done

# Bridge with neigh_snoop and no IP address, one port facing host-a.
grcli interface add bridge br0 neigh_suppress on neigh_snoop on
grcli interface add port p0 devargs net_tap0,iface=x-p0 domain br0

ip -n gr-repro link set x-p0 netns gr-host
ip -n gr-host link set x-p0 address 02:00:00:00:00:02 up
ip -n gr-host addr add 10.0.0.2/24 dev x-p0
sleep 1

# Gratuitous ARP from host-a.
ip netns exec gr-host arping -q -U -c2 -I x-p0 10.0.0.2 || true
sleep 1

echo "### $IMAGE"
grcli nexthop show
if grcli nexthop show | grep -q "br0 .*addr=10.0.0.2 "; then
	echo "PASS: 10.0.0.2 learned on br0"
else
	echo "FAIL: 10.0.0.2 not learned on br0"
	exit 1
fi
