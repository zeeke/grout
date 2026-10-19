#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Kernel-only baseline for EVPN IPv4 address mobility (VIP failover).
#
# Two Linux+FRR VTEPs, no grout. The bridge/VXLAN setup mirrors the
# OpenPERouter kernel dataplane: SVI (anycast gateway) on the bridge, VXLAN
# port with "nolearning" + bridge port "learning off" + "neigh_suppress on",
# and "advertise-all-vni" in FRR.
#
# A VIP is first owned by a host behind one VTEP, then moved to a host behind
# the other VTEP the way keepalived does it: the old host silently drops the
# address, the new host only sends gratuitous ARPs. The script checks whether
# the EVPN control plane converges on the new location and prints the state
# of every layer (kernel neigh, zebra EVPN arp-cache, BGP type-2 routes) at
# each step. It does not abort on the first failed check, it prints a summary.
#
#     .--------------------------.            .--------------------------.
#     |          vtep-a          |            |          vtep-b          |
#     |                          |            |                          |
#     |  vxlan100 (nh_suppress)  |            |  vxlan100 (nh_suppress)  |
#     |        |                 |            |        |                 |
#     |      br100  10.0.0.1/24  |    BGP     |      br100  10.0.0.1/24  |
#     |      |   |               |   EVPN     |      |   |               |
#     |     p1   p2      u0 .1 --+------------+-- u0 .2   p1   p2        |
#     '-----|----|---------------'  underlay  '------|----|--------------'
#           |    |               172.16.0.0/24       |    |
#     host-a .2  obs-a .4                      host-b .3  obs-b .5
#                                overlay
#                              10.0.0.0/24
#
# Each mode in $MODES runs in both directions with its own VIP so that one
# failure does not taint the next one: 10.0.0.1X (host-a -> host-b) and
# 10.0.0.2X (host-b -> host-a). See scenario() for the list of modes.
#
# Usage: sudo smoke/evpn_ip_mobility_kernel_frr_manualtest.sh <builddir>
#
# <builddir> must contain frr_install (the FRR built by meson for grout).
# Environment:
#   ARP_ACCEPT=0|1     net.ipv4.conf.br100.arp_accept on the VTEPs (default 0)
#   CONVERGE_WAIT=30   seconds to wait for convergence after each move
#   AGE_WAIT=0         seconds to watch the old VTEP entry if it did not move
#   MODES="garp5 garp1 gw probe vmac"   (also: periodic)
#   REFRESH_PERIOD=0   if >0, emulate the OpenPERouter BridgeRefresher: every
#                      REFRESH_PERIOD seconds, ping all STALE neighbours on
#                      br100 from each VTEP (default period there is 30s)
#   GARP_INTERVAL=5    "periodic" mode: interval of the new owner's GARPs

builddir=$(realpath "${1:?usage: $0 <builddir>}")
: "${ARP_ACCEPT:=0}"
: "${CONVERGE_WAIT:=30}"
: "${AGE_WAIT:=0}"
: "${REFRESH_PERIOD:=0}"
: "${GARP_INTERVAL:=5}"

set -e -o pipefail

if [ "${_SMOKE_UNSHARED:-}" != 1 ]; then
	export _SMOKE_UNSHARED=1
	exec unshare --mount --net -- "$0" "$@"
fi
mount --make-rprivate /
mkdir -p /run/netns
mount -t tmpfs tmpfs /run/netns
ip link set lo up

export PATH="$builddir/frr_install/sbin:$builddir/frr_install/bin:$PATH"
for d in etc/frr var/log/frr var/run/frr var/lib/frr; do
	mkdir -p "$builddir/frr_install/$d"
	mount -t tmpfs -o mode=1777 tmpfs "$builddir/frr_install/$d"
done

declare -a results
nfail=0

cleanup() {
	set +e +x
	kill $(jobs -p) 2>/dev/null
	for ns in vtep-a vtep-b; do
		frrinit.sh stop $ns >/dev/null 2>&1
	done
	for ns in $(ip netns list | awk '{print $1}'); do
		ip netns pids $ns | xargs -r kill -KILL 2>/dev/null
		ip netns del $ns
	done
}
trap cleanup EXIT

check() {
	local desc="$1"
	shift
	if "$@"; then
		results+=("PASS  $desc")
	else
		results+=("FAIL  $desc")
		nfail=$((nfail + 1))
	fi
}

# Print a command and its output, like a terminal session.
show() {
	echo "\$ $*"
	"$@" 2>&1 | sed 's/^/  /' || true
}

start_vtep_frr() {
	local ns="$1" id="$2" peer="$3"
	local conf="$builddir/frr_install/etc/frr/$ns"
	local log="$builddir/frr_install/var/log/frr/frr-$ns.log"

	mkdir -p "$conf"
	touch "$conf/vtysh.conf"
	cat >"$conf/daemons" <<EOF
bgpd=yes
vtysh_enable=yes
frr_global_options="-A 127.0.0.1 --log file:$log"
zebra_options="-s 90000000"
watchfrr_options="--netns=$ns"
EOF
	cat >"$conf/frr.conf" <<EOF
hostname $ns
router bgp 65000
 bgp router-id 172.16.0.$id
 no bgp default ipv4-unicast
 neighbor 172.16.0.$peer remote-as 65000
 address-family l2vpn evpn
  neighbor 172.16.0.$peer activate
  advertise-all-vni
 exit-address-family
exit
EOF
	frrinit.sh start $ns
}

wait_until() {
	local timeout="$1"
	shift
	SECONDS=0
	until "$@" >/dev/null 2>&1; do
		[ "$SECONDS" -ge "$timeout" ] && return 1
		sleep 1
	done
	return 0
}

# arp_cache_is <vtep> <ip> <local|remote> <mac>
arp_cache_is() {
	vtysh -N "$1" -c "show evpn arp-cache vni 100 json" |
		jq -e --arg ip "$2" --arg t "$3" --arg m "$4" \
		'.[$ip] | select(.type == $t and .mac == $m and .state == "active")'
}

# observer_resolves <ns> <ip> <mac>
observer_resolves() {
	ip -n "$1" neigh flush dev x-p1
	ip netns exec "$1" arping -c1 -w2 -I x-p1 "$2" | grep -qi "\[$3\]"
}

dump_state() {
	local ip="$1"
	local ns
	for ns in vtep-a vtep-b; do
		echo "---------------- $ns ----------------"
		show ip -n $ns -d neigh show $ip
		show bridge -n $ns fdb show br br100 master
		show vtysh -N $ns -c "show evpn arp-cache vni 100 ip $ip"
		show vtysh -N $ns -c "show evpn mac vni 100"
		show vtysh -N $ns -c "show bgp l2vpn evpn route type macip"
	done
}

# topology ---------------------------------------------------------------------
for ns in vtep-a vtep-b host-a host-b obs-a obs-b; do
	ip netns add $ns
	ip -n $ns link set lo up
done

ip link add u0 netns vtep-a type veth peer name u0 netns vtep-b

start_vtep_frr vtep-a 1 2
start_vtep_frr vtep-b 2 1

for x in a b; do
	ns=vtep-$x
	i=$([ $x = a ] && echo 1 || echo 2)
	ip netns exec $ns sysctl -qw net.ipv4.conf.all.forwarding=1
	ip -n $ns addr add 172.16.0.$i/24 dev u0
	ip -n $ns link set u0 up

	wait_until 10 sh -c "vtysh -N $ns -c 'show evpn' | grep -q 'L2 VNIs'" ||
		{ vtysh -N $ns -c "show evpn"; echo "zebra EVPN not enabled on $ns"; exit 1; }

	ip -n $ns link add br100 type bridge
	# anycast gateway: same IP and MAC on both VTEPs
	ip -n $ns link set br100 address 02:00:5e:00:01:01
	ip -n $ns addr add 10.0.0.1/24 dev br100
	ip netns exec $ns sysctl -qw net.ipv4.conf.br100.arp_accept=$ARP_ACCEPT
	ip -n $ns link set br100 up

	ip -n $ns link add vxlan100 type vxlan id 100 local 172.16.0.$i dstport 4789 nolearning
	ip -n $ns link set vxlan100 master br100
	ip -n $ns link set vxlan100 type bridge_slave neigh_suppress on learning off
	ip -n $ns link set vxlan100 up

	for h in host obs; do
		p=$([ $h = host ] && echo p1 || echo p2)
		ip -n $ns link add $p type veth peer name x-p1 netns $h-$x
		ip -n $ns link set $p master br100
		ip -n $ns link set $p up
	done
done

ip -n host-a link set x-p1 address 02:aa:00:00:00:02
ip -n host-b link set x-p1 address 02:bb:00:00:00:03
ip -n obs-a link set x-p1 address 02:aa:00:00:00:04
ip -n obs-b link set x-p1 address 02:bb:00:00:00:05
ip -n host-a addr add 10.0.0.2/24 dev x-p1
ip -n host-b addr add 10.0.0.3/24 dev x-p1
ip -n obs-a addr add 10.0.0.4/24 dev x-p1
ip -n obs-b addr add 10.0.0.5/24 dev x-p1
for ns in host-a host-b obs-a obs-b; do
	ip -n $ns link set x-p1 up
	ip -n $ns route add default via 10.0.0.1
	# Only answer ARP on the interface that owns the address (keepalived
	# with use_vmac requires this, otherwise x-p1 answers for vip0).
	ip netns exec $ns sysctl -qw net.ipv4.conf.all.arp_ignore=1
done

# OpenPERouter internal/hostnetwork/bridgerefresh: periodically ping STALE
# neighbours on the bridge so that live ones are refreshed and dead ones go
# PROBE -> FAILED, which makes zebra withdraw their type-2 route.
bridge_refresher() {
	local ns="$1"
	while sleep $REFRESH_PERIOD; do
		ip -n $ns -4 neigh show dev br100 nud stale | awk '{print $1}' |
		while read -r ip; do
			ip netns exec $ns ping -c1 -W1 -I br100 $ip >/dev/null 2>&1 &
		done
	done
}
if [ "$REFRESH_PERIOD" -gt 0 ]; then
	bridge_refresher vtep-a &
	bridge_refresher vtep-b &
fi

set -x

# Type-3 (flood VTEP) routes installed in both kernels.
wait_until 60 sh -c "bridge -n vtep-a fdb show dev vxlan100 | grep -q 'dst 172.16.0.2'"
wait_until 30 sh -c "bridge -n vtep-b fdb show dev vxlan100 | grep -q 'dst 172.16.0.1'"

# Learn all hosts on both sides.
for ns in host-a host-b obs-a obs-b; do
	ip netns exec $ns ping -c1 -W1 10.0.0.1
done
ip netns exec host-a ping -i0.2 -c3 -W1 10.0.0.3
ip netns exec host-b ping -i0.2 -c3 -W1 10.0.0.2
wait_until 10 arp_cache_is vtep-a 10.0.0.3 remote 02:bb:00:00:00:03
wait_until 10 arp_cache_is vtep-b 10.0.0.2 remote 02:aa:00:00:00:02
set +x

show uname -r
show vtysh -N vtep-a -c "show version"
show ip netns exec vtep-a sysctl net.ipv4.conf.br100.arp_accept
show ip -n vtep-a -d link show vxlan100
show bridge -n vtep-a -d link show dev vxlan100
show vtysh -N vtep-a -c "show evpn arp-cache vni 100"
show vtysh -N vtep-b -c "show evpn arp-cache vni 100"

# vip_dev <host-ns> <mode>: interface carrying the VIP on that host.
vip_dev() {
	[ "$2" = vmac ] && echo vip0 || echo x-p1
}

# vip_add <host-ns> <vip> <mode>
vip_add() {
	if [ "$3" = vmac ]; then
		# keepalived "use_vmac": the VIP lives on a macvlan carrying the
		# VRRP virtual MAC, so the MAC moves together with the IP.
		ip -n $1 link add vip0 link x-p1 address $VMAC type macvlan mode bridge
		ip -n $1 link set vip0 up
	fi
	ip -n $1 addr add $2/32 dev $(vip_dev $1 $3)
}

# vip_del <host-ns> <vip> <mode>
vip_del() {
	if [ "$3" = vmac ]; then
		ip -n $1 link del vip0
	else
		ip -n $1 addr del $2/32 dev x-p1
	fi
}

VMAC=00:00:5e:00:01:0a

# scenario <vip> <old a|b> <new a|b> <mode>
#
# Modes (what the new VIP owner does after the move):
#   garp1  one gratuitous ARP
#   garp5  five gratuitous ARPs, one per second (keepalived)
#   gw     five gratuitous ARPs, then an ARP request to the gateway
#          sourced from the VIP (ARP request "for us" on the new VTEP)
#   probe  five gratuitous ARPs; if not converged, make the old VTEP send
#          traffic to the VIP so that its stale neighbour gets probed,
#          then five more gratuitous ARPs (next keepalived round)
#   vmac   five gratuitous ARPs, VIP carried on a VRRP virtual MAC
#   periodic  one gratuitous ARP every GARP_INTERVAL seconds for the whole
#          convergence wait (keepalived garp_master_refresh)
scenario() {
	local vip="$1" old="$2" new="$3" mode="$4"
	local old_mac new_mac tag dev
	dev=$(vip_dev host-$old $mode)
	tag="$vip host-$old->host-$new $mode:"

	echo
	echo "######## $tag VIP owned by host-$old ########"
	vip_add host-$old $vip $mode
	old_mac=$(ip netns exec host-$old cat /sys/class/net/$dev/address)
	show ip netns exec host-$old arping -U -c3 -I $dev $vip
	# The VIP owner talks to the gateway using the VIP as source address,
	# this is how a VTEP without arp_accept learns the binding.
	show ip netns exec host-$old arping -c1 -w2 -s $vip -I $dev 10.0.0.1

	check "$tag vtep-$old has $vip local $old_mac before move" \
		wait_until 10 arp_cache_is vtep-$old $vip local $old_mac
	check "$tag vtep-$new has $vip remote $old_mac before move" \
		wait_until 10 arp_cache_is vtep-$new $vip remote $old_mac
	dump_state $vip

	echo
	echo "######## $tag move to host-$new ########"
	# keepalived: the old owner drops the VIP and goes silent, the new
	# owner adds it and only sends gratuitous ARPs (ARP requests sip=tip).
	vip_del host-$old $vip $mode
	vip_add host-$new $vip $mode
	local t_move=$(date +%s)
	new_mac=$(ip netns exec host-$new cat /sys/class/net/$dev/address)
	local garp_pid=
	if [ "$mode" = periodic ]; then
		ip netns exec host-$new arping -U -i $GARP_INTERVAL -I $dev $vip >/dev/null &
		garp_pid=$!
	elif [ "$mode" = garp1 ]; then
		show ip netns exec host-$new arping -U -c1 -I $dev $vip
	else
		show ip netns exec host-$new arping -U -c5 -I $dev $vip
	fi
	if [ "$mode" = gw ]; then
		show ip netns exec host-$new arping -c1 -w2 -s $vip -I $dev 10.0.0.1
	fi
	if [ "$mode" = probe ] && ! wait_until $CONVERGE_WAIT \
			arp_cache_is vtep-$new $vip local $new_mac; then
		echo "######## $tag not converged, probing stale entry from vtep-$old ########"
		dump_state $vip
		show ip netns exec vtep-$old ping -c3 -W1 $vip
		sleep 5
		show ip -n vtep-$old -d neigh show $vip
		show vtysh -N vtep-$old -c "show evpn arp-cache vni 100 ip $vip"
		show ip -n vtep-$new -d neigh show $vip
		show ip netns exec host-$new arping -U -c5 -I $dev $vip
	fi

	check "$tag vtep-$new has $vip local $new_mac after move" \
		wait_until $CONVERGE_WAIT arp_cache_is vtep-$new $vip local $new_mac
	check "$tag vtep-$old has $vip remote $new_mac after move" \
		wait_until 10 arp_cache_is vtep-$old $vip remote $new_mac
	echo "######## $tag checks done $(( $(date +%s) - t_move ))s after the move ########"
	[ -n "$garp_pid" ] && kill $garp_pid
	check "$tag obs-$old resolves $vip to $new_mac" \
		observer_resolves obs-$old $vip $new_mac
	check "$tag obs-$old can ping $vip" \
		ip netns exec obs-$old ping -c2 -W1 $vip
	check "$tag obs-$new resolves $vip to $new_mac" \
		observer_resolves obs-$new $vip $new_mac
	dump_state $vip
	show ip netns exec obs-$old arping -c1 -w2 -I x-p1 $vip

	if [ "$AGE_WAIT" -gt 0 ] && arp_cache_is vtep-$old $vip local $old_mac >/dev/null; then
		echo "######## $tag watching stale entry on vtep-$old for ${AGE_WAIT}s ########"
		SECONDS=0
		while [ "$SECONDS" -lt "$AGE_WAIT" ]; do
			echo "t=${SECONDS}s"
			show ip -n vtep-$old -d neigh show $vip
			show vtysh -N vtep-$old -c "show evpn arp-cache vni 100 ip $vip"
			sleep 10
		done
	fi
	vip_del host-$new $vip $mode
}

: "${MODES:=garp5 garp1 gw probe vmac}"
i=0
for mode in $MODES; do
	scenario 10.0.0.$((10 + i)) a b $mode
	scenario 10.0.0.$((20 + i)) b a $mode
	i=$((i + 1))
done

echo
echo "================ SUMMARY (ARP_ACCEPT=$ARP_ACCEPT) ================"
printf '%s\n' "${results[@]}"
[ "$nfail" -eq 0 ]
