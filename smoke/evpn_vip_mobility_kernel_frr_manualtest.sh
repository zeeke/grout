#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Kernel-only equivalent of evpn_vip_mobility_frr_test.sh: two Linux+FRR
# VTEPs, no grout involved.
#
# A virtual IP is moved between host-a (behind vtep-a) and host-b (behind
# vtep-b) the way keepalived does it: the old owner silently drops the address
# and the new owner announces it with gratuitous ARPs.
#
# 1. host-a owns the VIP. vtep-a learns it and advertises a Type-2 MAC+IP
#    route. vtep-b installs it as remote.
# 2. The VIP moves to host-b. vtep-b must learn it from the gratuitous ARPs
#    even though it currently has a remote neighbor for that address, zebra
#    must advertise it with a higher MAC mobility sequence number and vtep-a
#    must install it as remote with host-b's MAC.
# 3. The VIP moves back to host-a. vtep-a learns it again and vtep-b must
#    replace its local entry with the remote one.
#
# Each step also checks that the VIP is reachable through the overlay.
#
#     .-------------------------.          .-------------------------.
#     |         vtep-a          |          |         vtep-b          |
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
#     |  |   p1  |    |  u0   | |          | |  u0  |     |   p1  |  |
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
#
# Usage: sudo ./evpn_vip_mobility_kernel_frr_manualtest.sh [<frr_prefix>]
#
# <frr_prefix> is the FRR installation prefix (default: /usr). For a grout
# build directory, pass <builddir>/frr_install. Everything runs in private
# mount and network namespaces, FRR state directories are mounted as tmpfs.
#
# Requirements: iproute2, bridge, arping (iputils), jq, FRR with bgpd.
#
# Environment:
#   ARP_ACCEPT=0|1   net.ipv4.conf.br100.arp_accept on both VTEPs (default 0)
#   VERBOSE=0|1      print the state of every layer after each step (default 0)
#   TRAFFIC=none|hosts|vtep
#                    traffic generated after the VIP moves to host-b, followed
#                    by another round of gratuitous ARPs (default none):
#                    hosts: host-a pings the VIP and host-b (bridged overlay
#                           traffic, not routed by any VTEP)
#                    vtep:  vtep-a pings the VIP, so that its stale neighbor
#                           entry is probed

frr_prefix=$(realpath "${1:-/usr}")
: "${ARP_ACCEPT:=0}"
: "${VERBOSE:=0}"
: "${TRAFFIC:=none}"

set -e -o pipefail

if [ "${_VIP_UNSHARED:-}" != 1 ]; then
	export _VIP_UNSHARED=1
	exec unshare --mount --net -- "$0" "$@"
fi
mount --make-rprivate /
mkdir -p /run/netns
mount -t tmpfs tmpfs /run/netns
ip link set lo up

if [ "$frr_prefix" = /usr ]; then
	frr_etc=/etc/frr
	frr_var=/var
	frrinit=$(command -v frrinit.sh || echo /usr/lib/frr/frrinit.sh)
else
	frr_etc=$frr_prefix/etc/frr
	frr_var=$frr_prefix/var
	frrinit=$frr_prefix/sbin/frrinit.sh
fi
export PATH="$frr_prefix/sbin:$frr_prefix/bin:$PATH"
for d in $frr_etc $frr_var/log/frr $frr_var/run/frr $frr_var/lib/frr; do
	mkdir -p "$d"
	# FRR daemons drop privileges to the frr user
	mount -t tmpfs -o mode=1777 tmpfs "$d"
done

cleanup() {
	set +e +x
	for ns in vtep-a vtep-b; do
		$frrinit stop $ns >/dev/null 2>&1
	done
	for ns in $(ip netns list | awk '{print $1}'); do
		ip netns pids $ns | xargs -r kill -KILL 2>/dev/null
		ip netns del $ns
	done
}
trap cleanup EXIT

vip=10.0.0.10

# start_vtep <netns> <underlay addr> <peer underlay addr>
start_vtep() {
	local ns=$1 addr=$2 peer=$3
	local conf=$frr_etc/$ns

	mkdir -p $conf
	touch $conf/vtysh.conf
	cat >$conf/daemons <<-EOF
	bgpd=yes
	vtysh_enable=yes
	frr_global_options="-A 127.0.0.1 --log file:$frr_var/log/frr/$ns.log"
	zebra_options="-s 90000000"
	watchfrr_options="--netns=$ns"
	EOF
	cat >$conf/frr.conf <<-EOF
	hostname $ns
	router bgp 65000
	 bgp router-id $addr
	 no bgp default ipv4-unicast
	 neighbor $peer remote-as 65000
	 address-family l2vpn evpn
	  neighbor $peer activate
	  advertise-all-vni
	  advertise-svi-ip
	 exit-address-family
	exit
	EOF
	$frrinit start $ns
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

# -- Topology -------------------------------------------------------------------
ip netns add vtep-a
ip netns add vtep-b
ip link add u0 netns vtep-a type veth peer name u0 netns vtep-b

for x in a b; do
	ns=vtep-$x
	if [ $x = a ]; then
		addr=172.16.0.1 peer=172.16.0.2 svi=10.0.0.4
	else
		addr=172.16.0.2 peer=172.16.0.1 svi=10.0.0.1
	fi
	ip -n $ns link set lo up
	ip netns exec $ns sysctl -qw net.ipv4.conf.all.forwarding=1
	ip netns exec $ns sysctl -qw net.ipv4.conf.all.rp_filter=0
	ip netns exec $ns sysctl -qw net.ipv4.conf.default.rp_filter=0
	ip -n $ns addr add $addr/24 dev u0
	ip -n $ns link set u0 up

	start_vtep $ns $addr $peer
	poll 10 sh -c "vtysh -N $ns -c 'show evpn' | grep -q 'L2 VNIs'" || {
		vtysh -N $ns -c "show evpn"
		echo "fail: EVPN not enabled in zebra on $ns" >&2
		exit 1
	}

	ip -n $ns link add br100 type bridge
	ip netns exec $ns sysctl -qw net.ipv4.conf.br100.arp_accept=$ARP_ACCEPT
	ip -n $ns link set br100 up
	# linux needs an IP address in order to learn neighbors
	ip -n $ns addr add $svi/24 dev br100

	ip -n $ns link add vxlan100 type vxlan id 100 local $addr dstport 4789 nolearning
	ip -n $ns link set vxlan100 master br100
	ip -n $ns link set vxlan100 type bridge_slave neigh_suppress on learning off
	ip -n $ns link set vxlan100 up

	ip netns add host-$x
	ip -n host-$x link set lo up
	ip -n $ns link add p1 type veth peer name x-p1 netns host-$x
	ip -n $ns link set p1 master br100
	ip -n $ns link set p1 up
	ip -n host-$x link set x-p1 up
done
ip -n host-a addr add 10.0.0.2/24 dev x-p1
ip -n host-b addr add 10.0.0.3/24 dev x-p1

# Type-3 (flood VTEP) routes installed in both kernels.
poll 60 sh -c "bridge -n vtep-a fdb show dev vxlan100 | grep -q 'dst 172.16.0.2'" ||
	{ echo "fail: vtep-a did not install the flood entry" >&2; exit 1; }
poll 30 sh -c "bridge -n vtep-b fdb show dev vxlan100 | grep -q 'dst 172.16.0.1'" ||
	{ echo "fail: vtep-b did not install the flood entry" >&2; exit 1; }

mac_a=$(ip netns exec host-a cat /sys/class/net/x-p1/address)
mac_b=$(ip netns exec host-b cat /sys/class/net/x-p1/address)

# -- Helpers --------------------------------------------------------------------
# show <command...>: print a command and its output, like a terminal session.
show() {
	echo "\$ $*"
	"$@" 2>&1 | sed 's/^/  /' || true
}

dump_state() {
	local ns
	for ns in vtep-a vtep-b; do
		echo "---------------- $ns ----------------"
		show ip -n $ns -d neigh show $vip
		show bridge -n $ns fdb show br br100 master
		show vtysh -N $ns -c "show evpn arp-cache vni 100"
		show vtysh -N $ns -c "show bgp l2vpn evpn route type macip"
	done
}

# arp_cache_is <netns> <local|remote> <mac>: zebra EVPN arp-cache entry.
arp_cache_is() {
	vtysh -N $1 -c 'show evpn arp-cache vni 100 json' |
		jq -e --arg ip $vip --arg t "$2" --arg m "$3" \
		'.[$ip] | select(.type == $t and .mac == $m and .state == "active")'
}

# reaches <netns> <mac>: <netns> resolves the VIP to <mac> and can ping it.
reaches() {
	ip -n $1 neigh flush dev x-p1
	ip netns exec $1 ping -c1 -W1 $vip >/dev/null || return 1
	ip -n $1 neigh show $vip dev x-p1 | grep -qi "lladdr $2"
}

# check <timeout_sec> <message> <command...>
results=()
nfail=0
check() {
	local timeout=$1 msg=$2
	shift 2
	if poll $timeout "$@"; then
		results+=("PASS  $msg")
	else
		results+=("FAIL  $msg")
		nfail=$((nfail + 1))
	fi
}

# step <title>: print the step header.
step() {
	echo
	echo "######## $* ########"
}

# step_done: dump the state if any check failed so far, or if VERBOSE=1.
step_done() {
	if [ "$nfail" -gt 0 ] || [ "$VERBOSE" = 1 ]; then
		dump_state
	fi
}

# vip_add <netns>: take ownership of the VIP like keepalived does.
vip_add() {
	ip -n $1 addr add $vip/24 dev x-p1
	ip netns exec $1 arping -q -U -c3 -I x-p1 $vip || :
}

# vip_del <netns>: silently drop the VIP.
vip_del() {
	ip -n $1 addr del $vip/24 dev x-p1
}

show uname -r
show vtysh -N vtep-a -c "show version"
show ip netns exec vtep-a sysctl net.ipv4.conf.br100.arp_accept
echo "host-a MAC: $mac_a"
echo "host-b MAC: $mac_b"

# -- Initial state: host-a owns the VIP ---------------------------------------
step "1. host-a owns $vip"
vip_add host-a
# Linux does not learn neighbors from gratuitous ARPs unless arp_accept is set.
# Make host-a talk to its gateway using the VIP as source address.
ip netns exec host-a arping -q -c1 -w2 -s $vip -I x-p1 10.0.0.4 || :

check 10 "1. vtep-a learned $vip as local ($mac_a)" arp_cache_is vtep-a local $mac_a
check 10 "1. vtep-b installed $vip as remote ($mac_a)" arp_cache_is vtep-b remote $mac_a
check 5 "1. host-b reaches $vip on host-a" reaches host-b $mac_a
step_done

# -- Move the VIP to host-b -----------------------------------------------------
# vtep-b must learn the VIP from the gratuitous ARPs only.
step "2. $vip moves to host-b"
vip_del host-a
vip_add host-b

case "$TRAFFIC" in
hosts)
	show ip netns exec host-a ping -c3 -W1 $vip
	show ip netns exec host-a ping -c3 -W1 10.0.0.3
	;;
vtep)
	show ip netns exec vtep-a ping -c3 -W1 $vip
	# The neighbor goes PROBE -> FAILED, zebra withdraws the Type-2 route
	# and vtep-b removes its NOARP remote entry for the VIP.
	poll 30 sh -c "! vtysh -N vtep-b -c 'show evpn arp-cache vni 100 json' |
		jq -e '.[\"$vip\"].type == \"remote\"'" || :
	show ip -n vtep-a -d neigh show $vip
	show ip -n vtep-b -d neigh show $vip
	;;
esac
if [ "$TRAFFIC" != none ]; then
	ip netns exec host-b arping -q -U -c3 -I x-p1 $vip || :
fi

check 60 "2. vtep-b learned $vip as local ($mac_b)" arp_cache_is vtep-b local $mac_b
check 10 "2. vtep-a installed $vip as remote ($mac_b)" arp_cache_is vtep-a remote $mac_b
check 5 "2. host-a reaches $vip on host-b" reaches host-a $mac_b
step_done

# -- Move the VIP back to host-a ------------------------------------------------
step "3. $vip moves back to host-a"
vip_del host-b
vip_add host-a
ip netns exec host-a arping -q -c1 -w2 -s $vip -I x-p1 10.0.0.4 || :

check 10 "3. vtep-a learned $vip back as local ($mac_a)" arp_cache_is vtep-a local $mac_a
check 10 "3. vtep-b installed $vip back as remote ($mac_a)" arp_cache_is vtep-b remote $mac_a
check 5 "3. host-b reaches $vip back on host-a" reaches host-b $mac_a
step_done

echo
echo "================ SUMMARY (ARP_ACCEPT=$ARP_ACCEPT TRAFFIC=$TRAFFIC) ================"
printf '%s\n' "${results[@]}"
[ "$nfail" -eq 0 ]
