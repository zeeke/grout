#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Regression test for a grout zebra-plugin NHT race exposed by an FRR reload.
#
# The underlay ports are deliberately deleted and recreated while bgpd is
# restarting.  bgpd registers the directly-connected leaf addresses with
# zebra while grout emits the DOWN/address-delete/UP/address-add sequence.
# Before the fix this could leave BGP with an unresolved RNH (ifindex 0), so
# both peers remained Idle even though the final FRR configuration was valid.
#
# The remote ends are stable veths.  Only the grout ports are recreated, as
# happens when an OpenPERouter applies its underlay configuration.
#
#                    central AS 64514
#                 zebra + bgpd + grout
#                 .------------------.
#   leaf0 AS 64512 | p0 192.168.11.1  | veth-leaf0
#   leaf1 AS 64513 | p1 192.168.12.1  | veth-leaf1
#                 '------------------'
#
# Both IPv4 and IPv6 unicast families are explicitly activated for each BGP
# neighbor.  The TCP sessions use the IPv4 underlay, which exercises the RNH
# lookup for 192.168.11.0/24 and 192.168.12.0/24.

# Watchfrr normally waits 60 seconds before respawning a crashed daemon.  The
# short interval makes the reload sequence observable in a smoke-test budget.
export WATCHFRR_EXTRA_OPTS="--min-restart-interval=1"

# shellcheck source=smoke/_init_frr.sh
. "$(dirname "$0")/_init_frr.sh"

central_as=64514
leaf0_as=64512
leaf1_as=64513
leaf0_ip=192.168.11.2
leaf1_ip=192.168.12.2

# The host-side veths must outlive every grout port incarnation.  This makes
# the test race only the state managed by grout and its zebra plugin.
ip link add veth-central0 type veth peer name veth-leaf0
ip link add veth-central1 type veth peer name veth-leaf1
ip link set veth-central0 up
ip link set veth-central1 up

start_frr leaf0 0
start_frr leaf1 0

ip link set veth-leaf0 netns leaf0
ip link set veth-leaf1 netns leaf1
ip -n leaf0 link set veth-leaf0 up
ip -n leaf1 link set veth-leaf1 up
ip -n leaf0 addr add "$leaf0_ip/24" dev veth-leaf0
ip -n leaf0 addr add fd00:11::2/64 dev veth-leaf0
ip -n leaf1 addr add "$leaf1_ip/24" dev veth-leaf1
ip -n leaf1 addr add fd00:12::2/64 dev veth-leaf1

vtysh -N leaf0 <<-EOF
configure terminal
router bgp $leaf0_as
 bgp router-id 192.0.2.12
 no bgp ebgp-requires-policy
 neighbor 192.168.11.1 remote-as $central_as
 address-family ipv4 unicast
  neighbor 192.168.11.1 activate
 exit-address-family
 address-family ipv6 unicast
  neighbor 192.168.11.1 activate
 exit-address-family
exit
EOF

vtysh -N leaf1 <<-EOF
configure terminal
router bgp $leaf1_as
 bgp router-id 192.0.2.13
 no bgp ebgp-requires-policy
 neighbor 192.168.12.1 remote-as $central_as
 address-family ipv4 unicast
  neighbor 192.168.12.1 activate
 exit-address-family
 address-family ipv6 unicast
  neighbor 192.168.12.1 activate
 exit-address-family
exit
EOF

add_underlay_ports() {
	grcli interface add port p0 devargs net_tap0,remote=veth-central0
	grcli interface add port p1 devargs net_tap1,remote=veth-central1
}

del_underlay_ports() {
	grcli interface del p1
	grcli interface del p0
}

add_underlay_ports

# Persist the final configuration before the simulated reload.  When watchfrr
# respawns bgpd, it comes back with the same state an OpenPERouter applies:
# explicit v4/v6 underlay addresses and both AFs activated for both leaves.
set_ip_address --persist p0 192.168.11.1/24
set_ip_address --persist p0 fd00:11::1/64
set_ip_address --persist p1 192.168.12.1/24
set_ip_address --persist p1 fd00:12::1/64

_apply_frr_config 1 "" "
router bgp $central_as
 bgp router-id 192.0.2.14
 no bgp ebgp-requires-policy
 neighbor $leaf0_ip remote-as $leaf0_as
 neighbor $leaf1_ip remote-as $leaf1_as
 address-family ipv4 unicast
  neighbor $leaf0_ip activate
  neighbor $leaf1_ip activate
 exit-address-family
 address-family ipv6 unicast
  neighbor $leaf0_ip activate
  neighbor $leaf1_ip activate
 exit-address-family
exit"

wait_bgp_established() {
	local peer="$1"
	local timeout="${2:-30}"

	SECONDS=0
	while ! vtysh -c "show bgp summary json" 2>/dev/null | \
		jq -e ".ipv4Unicast.peers.\"$peer\".state == \"Established\"" >/dev/null; do
		if [ "$SECONDS" -ge "$timeout" ]; then
			vtysh -c "show bgp summary"
			vtysh -c "show ip nht"
			fail "BGP peer $peer did not establish within ${timeout}s"
		fi
		sleep 0.2
	done
}

assert_bgp_recovered() {
	local cycle="$1"

	wait_bgp_established "$leaf0_ip"
	wait_bgp_established "$leaf1_ip"
}

assert_bgp_recovered initial

# Do not use frr-reload.py here: the failure requires a bgpd restart as well
# as the following grout underlay recreation.  Start the port replacement just
# before watchfrr's one-second respawn deadline.  This makes the RNH register
# from the new bgpd race the connected-route and neighbor notifications while
# zebra remains alive, which is the failing OpenPERouter sequence.
restart_bgpd_during_underlay_recreate() {
	local cycle="$1"
	local pid_file="$builddir/frr_install/var/run/frr/bgpd.pid"
	local old_pid new_pid

	old_pid=$(cat "$pid_file")
	kill -9 "$old_pid"

	{
		sleep 0.8
		# This is the controller's reconfiguration edge: it emits
		# GR_EVENT_IFACE_POST_RECONFIG before the port recreation below.
		grcli interface set port p0 description "nht-reload-$cycle"
		grcli interface set port p1 description "nht-reload-$cycle"
		del_underlay_ports
		add_underlay_ports
	} &
	local reconfigure_pid=$!

	SECONDS=0
	while :; do
		new_pid=$(cat "$pid_file" 2>/dev/null || true)
		if [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] && \
			kill -0 "$new_pid" 2>/dev/null; then
			break
		fi
		[ "$SECONDS" -lt 10 ] || fail "watchfrr did not respawn bgpd within 10s"
		sleep 0.05
	done

	wait "$reconfigure_pid"
}

cycles="${BGP_NHT_RELOAD_CYCLES:-1}"
for cycle in $(seq 1 "$cycles"); do
	mark_events
	restart_bgpd_during_underlay_recreate "$cycle"

	# The ports are recreated asynchronously.  In particular, do not register
	# success merely because the interface object exists; zebra must have put the
	# persisted addresses back before the NHT/BGP assertion below.
	wait_event -t 10 "iface reconf: p0 type=port"
	wait_event -t 10 "iface reconf: p1 type=port"
	wait_kernel_addr 192.168.11.1/24 p0
	wait_kernel_addr 192.168.12.1/24 p1
	assert_bgp_recovered "$cycle"
done

true
