#!/bin/bash
# Regenerates the excerpts in this directory from the raw CI artifacts in raw/.
#
# Nodes and workloads in the failing test:
#   pe-kind-control-plane  router pod qts9b  VTEP 100.65.0.0  pod1 192.171.24.2 46:cd:e2:e6:d1:6c
#   pe-kind-worker         router pod 2jmrq  VTEP 100.65.0.1  pod2 192.171.24.3 f6:ce:79:73:0c:48
#   pe-kind-worker2        router pod nqgwj  VTEP 100.65.0.2  (no test pod)

set -e -o pipefail
cd "$(dirname "$0")"

POD1_MAC=46:cd:e2:e6:d1:6c
POD2_MAC=f6:ce:79:73:0c:48
POD2_IP=192.171.24.3
NODES="pe-kind-control-plane pe-kind-worker pe-kind-worker2"

# section <file.gz> <header>: print one "######## <header>" block of an frrdump.
section() {
	zcat "$1" | awk -v h="######## $2" '
		$0 == h {p = 1; print; next}
		/^######## / {p = 0}
		p {print}'
}

{
	echo "# e2e failure (job log tail, raw/e2e-job-log-tail.txt.gz)"
	echo
	zcat raw/e2e-job-log-tail.txt.gz | cut -f3- | sed 's/\x1b\[[0-9;]*m//g; s/\^\[\[[0-9;]*m//g' |
		awk '$1 >= "2026-10-20T10:08:10" && $1 < "2026-10-20T10:11:01"' |
		grep -E "STEP|FAILED|Timed out|curl: \(28\)|failed at|exec in pod"
} > 01-test-failure.txt

{
	echo "# Test pods (raw/test-pods.yaml)"
	echo
	grep -E "^    name: pod|^    nodeName:|^    podIP:" raw/test-pods.yaml
	echo
	echo "# The pods' L2VNI addresses/MACs come from the grout neighbor tables below:"
	echo "#   pod1 192.171.24.2 $POD1_MAC on pe-kind-control-plane"
	echo "#   pod2 $POD2_IP $POD2_MAC on pe-kind-worker"
} > 02-pods.txt

{
	echo "# leafSRV6: the return route to the L2VNI subnet 192.171.24.0/24 is ECMP"
	echo "# over the SRv6 SIDs of all three nodes (fd00:0:32/33/34)."
	echo
	zcat raw/frrdump-leafSRV6.log.gz | grep -A3 "^192.171.24.0/24 nhid"
	echo
	section raw/frrdump-leafSRV6.log.gz "BGP route table ipv4 vpn (SRv6)" | grep -B1 -A2 "192.171.24.0/24"
} > 03-leafSRV6-ecmp-return-path.txt

{
	echo "# EVPN routes as seen by each node. pod1's type-2 ($POD1_MAC / 192.171.24.2)"
	echo "# is everywhere; pod2's type-2 ($POD2_MAC / $POD2_IP) is nowhere,"
	echo "# not even on pe-kind-worker, the node hosting pod2."
	for n in $NODES; do
		echo
		echo "================ $n"
		section raw/frrdump-router-$n.log.gz "EVPN Routes" | grep -E "Route Distinguisher|\[2\]|\[3\]"
	done
} > 04-evpn-type2-per-node.txt

{
	echo "# grout state on each node at dump time ($(cat raw/dump-timestamp.txt))."
	echo "# On pe-kind-worker grout has learned pod2's MAC on pe-110 and its neighbor"
	echo "# entry, but zebra/BGP never got to know them (see 04 and 06)."
	for n in $NODES; do
		echo
		echo "================ $n: grcli fdb show"
		section raw/frrdump-router-$n.log.gz "grcli fdb show"
		echo "================ $n: grcli nexthop show (L2VNI bridge neighbors)"
		section raw/frrdump-router-$n.log.gz "grcli nexthop show" | grep "br-pe-110.*addr=192.171.24" || :
	done
	echo
	echo "================ pe-kind-worker: grcli stats show (selected)"
	section raw/frrdump-router-pe-kind-worker.log.gz "grcli stats show" |
		grep -E "^NODE|bridge_input|bridge_flood|vxlan_flood|ctlplane|nexthop\."
} > 05-grout-state.txt

{
	echo "# zebra (dplane_grout) log on pe-kind-worker, from the L2VNI setup of the"
	echo "# failing test until the first curl retries."
	echo "#"
	echo "# - GR_EVENT_FDB_ADD/DEL and grout_macfdb_change: FDB events received from grout."
	echo "#   The last one is at 10:08:18.650; there is none for $POD2_MAC."
	echo "# - GR_NH_DEL: zebra's own nexthop deletions, each of which drains grout's"
	echo "#   control queue while zebra's request is being processed."
	echo "# - The first event about $POD2_IP is a NEXTHOP_UPDATE (the NEXTHOP_NEW is"
	echo "#   missing too). zebra gets neighbor updates but never sends 'MACIP Add'"
	echo "#   to bgpd, because it has no local MAC for $POD2_MAC."
	echo
	zcat raw/frr-log-router-pe-kind-worker.log.gz |
		awk '$2 >= "10:08:14" && $2 < "10:08:36"' |
		grep -E "GR_EVENT_FDB|grout_macfdb_change|GR_NH_DEL|neigh_notify.*iface=8 192\.171|MACIP" |
		cut -c1-220
	echo
	echo "# First grout event about pod2 ($POD2_IP $POD2_MAC): a NEXTHOP_UPDATE;"
	echo "# the NEXTHOP_NEW and the FDB_ADD were never received."
	zcat raw/frr-log-router-pe-kind-worker.log.gz |
		grep -B3 "neigh_notify: add neigh iface=8 $POD2_IP $POD2_MAC" | head -4 | cut -c1-220 || :
	echo
	echo "# Contrast: a pod of an earlier test with the same IP on the same node, at 10:05:19:"
	echo "# FDB_ADD (grout_macfdb_change) and NEXTHOP_NEW were both received."
	zcat raw/frr-log-router-pe-kind-worker.log.gz |
		grep -B4 "neigh_notify: add neigh iface=8 $POD2_IP " | head -5 | cut -c1-220 || :
	echo
	echo "# Every message about $POD2_MAC in the whole log (no FDB event, no MACIP):"
	zcat raw/frr-log-router-pe-kind-worker.log.gz | { grep -c "$POD2_MAC" || :; } | sed 's/^/total lines: /'
	zcat raw/frr-log-router-pe-kind-worker.log.gz | grep "$POD2_MAC" | { grep -vc "grout_neigh_notify" || :; } |
		sed 's/^/lines other than grout_neigh_notify: /'
} > 06-zebra-timeline-worker.txt

{
	echo "# Contrast: on pe-kind-control-plane, pod1's MAC is notified by grout"
	echo "# (grout_macfdb_change add) and zebra hands it to bgpd (MACIP Add), which"
	echo "# advertises the type-2 routes."
	echo
	zcat raw/frr-log-router-pe-kind-control-plane.log.gz |
		awk '$2 >= "10:08:29" && $2 < "10:08:31"' |
		grep -E "grout_macfdb_change|neigh_notify.*192\.171|MACIP|send UPDATE.*\[2\]" | cut -c1-220 || :
} > 07-zebra-timeline-control-plane-ok.txt

echo "excerpts regenerated in $(pwd)"
