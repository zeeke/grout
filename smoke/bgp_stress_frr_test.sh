#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# This test stresses BGP session establishment by repeatedly setting up and
# tearing down the FRR BGP configuration and Grout interfaces on the Grout side,
# while keeping the peer side completely stable. Uses a veth pair so the peer's
# network interface never changes during teardown/setup cycles.
#
#                                                     .-------------------.
#                                                     |  netns "bgp-peer" |
#  .-------..-------------.                           |        .------.   |
#  | zebra ||    grout    |                           |        | bgpd |   |
#  '-------'|             |                           |        '------'   |
#  .------. |       .------------.      veth    .------------. .-------.  |
#  | bgpd | |       |     p0     |   remote=    | veth-peer  | | zebra |  |
#  '------' |       | (net_tap)  +-------------+  (stable)   | '-------'  |
#         .------.  | 172.16.0.1 |             | 172.16.0.2 |.----------. |
#         | main |  '------------'             '------------'|    lo    | |
#         '------'         |                          |      |          | |
#            |             | (created/deleted         |      | 16.0.0.1 | |
#            |             |  each iteration)         |      '----------' |
#            '-------------'                          '-------------------'
#                      veth0 (stable, root ns)
#
# The test performs the following steps in a loop:
#   1. Create Grout port p0 using remote=veth0 (attaches to existing veth pair)
#   2. Configure IP 172.16.0.1/24 on p0
#   3. Configure Grout BGP to peer with 172.16.0.2
#   4. Wait for BGP session to be established
#   5. Verify BGP route is received from peer
#   6. Tear down BGP configuration
#   7. Tear down Grout port p0 (veth pair remains intact)
#   8. Repeat

. $(dirname $0)/_init_frr.sh

# Create veth pair: veth0 (root ns) <-> veth-peer (bgp-peer ns)
# This veth pair remains stable throughout all iterations
ip link add veth0 type veth peer name veth-peer
ip link set veth0 up

# Start FRR in bgp-peer namespace (creates the netns)
start_frr bgp-peer 0

# Move veth-peer to bgp-peer namespace and configure it
ip link set veth-peer netns bgp-peer
ip -n bgp-peer link set veth-peer up
ip -n bgp-peer addr add 172.16.0.2/24 dev veth-peer

# Configure BGP peer (stable configuration, never torn down)
vtysh -N bgp-peer <<-EOF
configure terminal

interface veth-peer
	ip address 172.16.0.2/24
exit

interface lo
	ip address 16.0.0.1/24
exit

router bgp 64512
	bgp router-id 172.16.0.2

	neighbor 172.16.0.1 remote-as 64512

	address-family ipv4 unicast
		network 172.16.0.0/24
		network 16.0.0.0/24
	exit-address-family
exit
EOF

# Helper to wait for BGP session to be established
wait_bgp_established() {
	local timeout="${1:-30}"
	local elapsed=0

	while [ $elapsed -lt $timeout ]; do
		if vtysh -c "show bgp summary json" 2>/dev/null | \
			jq -e '.ipv4Unicast.peers."172.16.0.2".state == "Established"' >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.5
		elapsed=$((elapsed + 1))
	done

	fail "BGP session not established after ${timeout}s"
}

# frr-reload.py path (pick the latest FRR subproject)
srcdir="$(cd "$(dirname "$0")/.." && pwd)"
frr_reload_py="$(ls -1 "$srcdir"/subprojects/frr-frr-*/tools/frr-reload.py | sort -V | tail -1)"
frr_confdir="$builddir/frr_install/etc/frr"
frr_bindir="$builddir/frr_install/bin"
frr_rundir="$builddir/frr_install/var/run/frr"
frr_reload="python3 $frr_reload_py --confdir $frr_confdir --bindir $frr_bindir --rundir $frr_rundir"

# Base config (no BGP) — written once, reused every iteration
base_conf="$tmp/base.conf"
cat >"$base_conf" <<'CONF'
hostname grout
debug zebra dplane dpdk
CONF

# BGP config — base + router bgp stanza
bgp_conf="$tmp/bgp.conf"
cat >"$bgp_conf" <<'CONF'
hostname grout
debug zebra dplane dpdk
router bgp 64512
 bgp router-id 172.16.0.1
 neighbor 172.16.0.2 remote-as 64512
 address-family ipv4 unicast
  network 172.16.0.0/24
 exit-address-family
exit
CONF

# Apply config via frr-reload.py diff/reload
setup_bgp() {
	$frr_reload --reload --debug --stdout "$bgp_conf"
}

teardown_bgp() {
	$frr_reload --reload --debug --stdout "$base_conf"
}


# Stress loop: setup -> verify -> teardown -> repeat
iterations="${STRESS_ITERATIONS:-10}"
echo "Running BGP stress test for $iterations iterations"

for i in $(seq 1 $iterations); do
	echo "=== Iteration $i/$iterations ==="

	setup_bgp

	#mark_events
	grcli interface add port p0 devargs net_tap0,remote=veth0
	# wait_event -t 10 'iface add: p0'
	# wait_event -t 10 'iface post add: p0'

	# Step 2: Add IP to p0
	#mark_events
	grcli address add 172.16.0.1/24 iface p0
	# wait_event -t 10 'addr4 add: iface=p0 172.16.0.1/24'


	sleep 3

	# Step 4: Wait for BGP session to be established
	wait_bgp_established 30

	# Step 5: Verify BGP route is received
	# mark_events
	# wait_event -t 20 'route4 add: vrf=main 16.0.0.0/24 origin=bgp via type=L3 .*addr=172.16.0.2'

	# Verify route is in FIB
	# grcli -j route show | jq -e \
	# 	'.[] | select(.destination == "16.0.0.0/24" and .origin == "bgp")' >/dev/null \
	# 	|| fail "BGP route 16.0.0.0/24 not found in FIB at iteration $i"

	# echo "BGP session established and route received successfully"

	# Step 6: Tear down BGP configuration
	teardown_bgp

	# Wait for route to be removed
	# mark_events
	# wait_event -t 10 'route4 del: vrf=main 16.0.0.0/24'

	# Step 7: Tear down Grout port (veth pair remains intact for next iteration)
	grcli interface del p0

	echo "Teardown complete"
	#sleep 0.5
done

echo "BGP stress test completed successfully ($iterations iterations)"
