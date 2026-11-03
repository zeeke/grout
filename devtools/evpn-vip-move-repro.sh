#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
#
# A floating IP (VIP) moves from host-a (behind vtep-a) to host-b (behind
# vtep-b), which announces it with gratuitous ARPs like keepalived. Both VTEPs
# are grout + FRR with EVPN neigh_suppress. vtep-a must learn the new MAC.
#
#   host-a --- vtep-a ===( spine: VXLAN + BGP EVPN )=== vtep-b --- host-b
#
# Usage: sudo devtools/evpn-vip-move-repro.sh [--fixed]
#
#   --fixed  Use localhost/grout-vipfix: the unpatched image with grout and
#            grcli replaced by binaries built with the fix.

set -euo pipefail

image=${GROUT_IMAGE:-quay.io/grout/grout:0.19.3}
[ "${1:-}" = --fixed ] && image=localhost/grout-vipfix
vip=10.0.0.10
mac_a=02:00:00:00:00:0a
mac_b=02:00:00:00:00:0b
# Bridge (SVI) addresses of vtep-a and vtep-b.
svi_a=10.0.0.251
svi_b=10.0.0.252
containers="vtep-a vtep-b host-a host-b spine"

pid() { podman inspect -f '{{.State.Pid}}' vipmv-$1; }
# Run a host binary in the network namespace of container $1.
nse() { local c=$1; shift; nsenter -t "$(pid $c)" -n "$@"; }
gr() { local c=$1; shift; podman exec vipmv-$c grcli "$@"; }

# wait_for <seconds> <command...>
wait_for() {
	local timeout=$1
	shift
	SECONDS=0
	until "$@" >/dev/null 2>&1; do
		[ "$SECONDS" -ge "$timeout" ] && { echo "timeout: $*" >&2; return 1; }
		sleep 0.5
	done
}

# tag <name>: prefix every line of stdin with the time and [<name>].
tag() {
	local l t
	while IFS= read -r l; do
		t=$EPOCHREALTIME # seconds and microseconds, the separator depends on locale
		printf '%(%T)T.%s %-14s %s\n' "${t%[.,]*}" "${t: -6:3}" "[$1]" "$l"
	done >&3
}
log() { echo "==> $*"; }
# Everything the script itself prints is tagged [script].
exec 3>&1
exec > >(tag script) 2>&1

cleanup() {
	for c in $containers; do podman rm -f -t0 vipmv-$c >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

cleanup

for c in $containers; do
	podman run -d --name vipmv-$c --network none --privileged \
		-e GROUT_OVERRIDE_DEFAULT_ROUTE=true -e GROUT_OVERRIDE_RP_FILTER=true \
		--entrypoint sleep "$image" infinity >/dev/null
done

# move_tap <vtep> <tap> <container> <name> [<mac>]
move_tap() {
	wait_for 10 nse $1 ip link show $2
	nse $1 ip link set $2 netns "$(pid $3)"
	nse $3 ip link set $2 name $4 ${5:+address $5} up
}

# -- underlay -------------------------------------------------------------------

nse spine ip link add ul up type bridge
n=0
for v in vtep-a vtep-b; do
	n=$((n + 1))
	podman exec vipmv-$v grout --test-mode -m 0666 -v -x 2>&1 | tag "$v grout" &
	wait_for 30 podman exec vipmv-$v test -S /run/grout.sock
	gr $v interface add port p0 devargs net_tap0,iface=x-p0
	gr $v address add 172.16.0.$n/24 iface p0
	# The kernel side of a net_tap has the MAC of the grout port, and a linux
	# bridge keeps frames for its ports' MACs: give the kernel side another MAC.
	move_tap $v x-p0 spine $v 02:00:00:00:ff:0$n
	nse spine ip link set $v master ul
done
podman exec vipmv-vtep-a grout -V

# -- EVPN -----------------------------------------------------------------------

# setup_vtep <vtep> <underlay> <peer> <svi addr> <host> <host mac> <host addr>
setup_vtep() {
	local v=$1 self=$2 peer=$3 svi=$4
	podman exec -i vipmv-$v sh -c 'cat > /etc/frr/daemons' <<-EOF
	bgpd=yes
	vtysh_enable=yes
	frr_global_options="--log file:/tmp/frr.log --log-level debug"
	zebra_options="-A 127.0.0.1 -s 90000000 -M dplane_grout --limit-fds 100000"
	bgpd_options="-A 127.0.0.1 --limit-fds 100000"
	staticd_options="-A 127.0.0.1 --limit-fds 100000"
	EOF
	podman exec vipmv-$v sh -c 'touch /tmp/frr.log && exec tail -n0 -F /tmp/frr.log' |
		sed -u -E 's,^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:.]+ ,,' | tag "$v frr" &
	podman exec vipmv-$v /usr/libexec/frr/frrinit.sh start >/dev/null 2>&1
	podman exec -i vipmv-$v vtysh >/dev/null <<-EOF
	configure terminal
	debug zebra dplane dpdk
	debug zebra vxlan
	debug zebra events
	debug bgp updates
	debug bgp zebra
	router bgp 65000
	 bgp router-id $self
	 no bgp default ipv4-unicast
	 neighbor $peer remote-as 65000
	 address-family l2vpn evpn
	  neighbor $peer activate
	  advertise-all-vni
	  advertise-svi-ip
	EOF
	wait_for 30 sh -c "podman exec vipmv-$v vtysh -c 'show evpn' | grep -q 'L2 VNIs'"

	gr $v interface add bridge br100 neigh_suppress on neigh_snoop on
	gr $v address add $svi/24 iface br100
	gr $v interface add vxlan vxlan100 vni 100 local $self domain br100
	wait_for 15 sh -c "podman exec vipmv-$v vtysh -c 'show evpn vni 100' | grep -q 'VNI: 100'"
	gr $v interface add port p1 devargs net_tap1,iface=x-p1 domain br100
	gr $v nexthop config set lifetime 30 unreachable 60 ucast-probes 3 bcast-probes 3

	move_tap $v x-p1 $5 eth0 $6
	nse $5 ip addr add $7 dev eth0
	wait_for 60 sh -c "podman exec vipmv-$v grcli flood vtep show | grep -q $peer"
}
log "setting up EVPN"
setup_vtep vtep-a 172.16.0.1 172.16.0.2 $svi_a host-a $mac_a 10.0.0.2/24 &
a=$!
setup_vtep vtep-b 172.16.0.2 172.16.0.1 $svi_b host-b $mac_b 10.0.0.3/24 &
b=$!
wait $a && wait $b

# -- VIP on host-a, then moved to host-b with no gap ----------------------------

log "VIP $vip on host-a ($mac_a)"
nse host-a ip addr add $vip/32 dev eth0
nse host-a ping -c1 -W1 -I $vip $svi_a >/dev/null || true
wait_for 20 sh -c "podman exec vipmv-vtep-b grcli nexthop show | grep -q 'addr=$vip .*mac=$mac_a .*remote'"

log "VIP moves to host-b ($mac_b)"
nse host-a ip addr del $vip/32 dev eth0
nse host-b ip addr add $vip/32 dev eth0
# Gratuitous ARP requests (sender IP == target IP), like keepalived.
nse host-b arping -U -c5 -I eth0 $vip >/dev/null || true

# vtep-a must have learned the VIP's new MAC from the gratuitous ARPs.
status=0
wait_for 60 sh -c "podman exec vipmv-vtep-a grcli nexthop show | grep -q 'addr=$vip .*mac=$mac_b'" || status=1
show() {
	for v in vtep-a vtep-b; do
		log "$v: $(gr $v nexthop show | grep "addr=$vip " || echo "no nexthop for $vip")"
	done
}
show
[ "$status" -eq 0 ] && log "PASS: vtep-a knows $vip is at $mac_b" ||
	log "FAIL: vtep-a still has a stale entry for $vip"

log "sleeping 600s"
sleep 600
show
exit $status
