#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Andrea Panattoni

# Verify grout recovers cleanly when TAP interfaces are destroyed
# externally: by deleting the network namespace that contains the
# datapath TAP, or when the grout port is removed via the API. Also
# confirm grout itself survives a SIGKILL and can be restarted with
# the same configuration.
#
# Each grout port backed by the net_tap PMD has two Linux TAP devices:
#   - The control-plane TAP (named after the grout interface, e.g. "p0"),
#     created by ctlplane.c, monitored via libevent EV_CLOSED.
#   - The datapath TAP (prefixed "x-", e.g. "x-p0"), created by the
#     DPDK net_tap driver, moved to a peer namespace in tests.

. $(dirname $0)/_init.sh

# ── 1. Delete the grout port via the API ─────────────────────────────
# Normal path: grcli interface del triggers iface_destroy which closes
# the TAP fd and frees all resources.

port_add p0
grcli address add 172.16.0.1/24 iface p0

netns_add n0
move_to_netns x-p0 n0
ip -n n0 addr add 172.16.0.2/24 dev x-p0

grcli ping 172.16.0.2 delay 10 count 3

mark_events

grcli interface del p0

wait_event "iface del: p0"

grcli -j interface show | jq -e '.[] | select(.name == "p0")' \
	&& fail "p0 should be gone after API deletion"

# The CP TAP should also be gone.
ip link show p0 2>/dev/null && fail "CP TAP p0 should be gone"

# The datapath TAP in the peer namespace should also be gone: closing
# the DPDK net_tap fd destroys the kernel device.
ip -n n0 link show x-p0 2>/dev/null && fail "datapath TAP x-p0 should be gone from n0"

# ── 2. Delete the namespace containing the datapath TAP ─────────────
# Destroying the netns removes the "x-" datapath TAP. The CP TAP is
# unaffected so grout does not auto-destroy the port. Verify grout
# stays healthy and the port can still be cleaned up via the API.

port_add p1
grcli address add 172.16.1.1/24 iface p1

netns_add n1
move_to_netns x-p1 n1
ip -n n1 addr add 172.16.1.2/24 dev x-p1

grcli ping 172.16.1.2 delay 10 count 3

# Kill processes inside the netns before deleting it.
ip netns pids n1 | xargs -r kill -TERM 2>/dev/null || true
sleep 0.5
ip netns pids n1 | xargs -r kill -KILL 2>/dev/null || true
ip netns del n1

# Give grout a moment to notice the peer is gone.
sleep 0.5

# The port should still exist: only the datapath TAP was destroyed,
# the CP TAP is still alive.
grcli -j interface show name p1 | jq -e 'select(.name == "p1")' \
	|| fail "p1 should still exist after namespace deletion"

# Clean it up via the API.
mark_events
grcli interface del p1

wait_event "iface del: p1"

grcli -j interface show | jq -e '.[] | select(.name == "p1")' \
	&& fail "p1 should be gone after API deletion"

# ── 3. Kill and restart grout ────────────────────────────────────────
# After a SIGKILL, grout should restart cleanly and accept the same
# port configuration. Validates that stale PBR rules from the previous
# instance are flushed on startup (netlink_flush_cp_route_table).

port_add p2
grcli address add 172.16.2.1/24 iface p2

netns_add n2
move_to_netns x-p2 n2
ip -n n2 addr add 172.16.2.2/24 dev x-p2

grcli ping 172.16.2.2 delay 10 count 3

restart_grout

# SIGKILL closed the DPDK net_tap fd, destroying the original x-p2
# in n2. Recreate the port and re-establish the namespace plumbing.
grcli route config set default rib4-routes 128 rib6-routes 128
grcli interface add port p2 devargs net_tap$((tap_counter - 1)),iface=x-p2
grcli address add 172.16.2.1/24 iface p2

move_to_netns x-p2 n2
ip -n n2 addr add 172.16.2.2/24 dev x-p2

grcli ping 172.16.2.2 delay 10 count 3

# ── 4. Verify final state after all disruptions ─────────────────────
# Only p2 should remain.
count=$(grcli -j interface show type port | jq length)
if [ "$count" -ne 1 ]; then
	fail "expected 1 port interface, got $count"
fi

grcli -j interface show name p2 | jq -e 'select(.name == "p2")' \
	|| fail "p2 should still exist"
