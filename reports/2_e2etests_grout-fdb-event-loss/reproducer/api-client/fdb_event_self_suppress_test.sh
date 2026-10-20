#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause

# Datapath-learned FDB entries must be notified to subscribers that use
# suppress_self_events, even when that subscriber's process has API
# requests in flight (e.g. zebra issuing GR_NH_DEL while hosts come up).

. $(dirname $0)/_init.sh

grcli interface add bridge br0
port_add p0 domain br0

# Keep the kernel quiet on x-p0 so that only the injected frames are learned.
sysctl -qw net.ipv6.conf.x-p0.disable_ipv6=1
ip link set x-p0 up

# Control run: no concurrent requests from the subscriber process.
fdb_event_watch -x -i x-p0 -n 100 || fail "GR_EVENT_FDB_ADD lost without concurrent requests"

grcli fdb flush bridge br0

# Same process issues GR_NH_ADD/GR_NH_DEL while MACs are being learned.
fdb_event_watch -i x-p0 -n 100 || fail "GR_EVENT_FDB_ADD lost while the subscriber had requests in flight"
