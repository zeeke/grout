# Datapath events drained inside an API handler are suppressed for the requesting client (lost `GR_EVENT_FDB_ADD` → missing EVPN type-2 routes)

## Summary

Events that datapath workers queue on the control queue (for example,
`GR_EVENT_FDB_ADD` from `fdb_learn()`) are delivered as if they had been
caused by whichever API request triggers `control_queue_drain()`. When that
request comes from a client that subscribed with
`suppress_self_events = true`, the event is silently dropped for that client.

The FRR dplane plugin is such a client. zebra subscribes to `GR_EVENT_FDB_*`
and `GR_EVENT_NEXTHOP_*` with `suppress_self_events = true` and routinely sends
`GR_NH_DEL`. Each `GR_NH_DEL` ends in `nexthop_destroy()`, which drains the
control queue. A MAC learned in that window is in the grout FDB, but zebra
never hears about it. Since `fdb_learn()` only emits `GR_EVENT_FDB_ADD` when it
creates the entry, and an active host keeps refreshing that entry, the loss is
permanent. No EVPN type-2 route is advertised for the host, and traffic to it
from remote VTEPs is black-holed.

Affected: v0.19.0 through current `main` (846ee040).

## Reproducer: shell only (`grcli` + `vtysh`)

`smoke/evpn_fdb_event_lost_frr_test.sh` (attached as a patch, full script
below):

1. VNI 100 on a grout bridge, `advertise-all-vni` in FRR. No BGP peer needed.
2. Hosts are macvlan interfaces stacked on the kernel side of a bridge member.
   Bringing one up makes the kernel send DAD/MLD frames from its MAC, which
   grout learns.
3. Phase 1, zebra idle: 20 hosts. Every MAC must be `local` in
   `show evpn mac vni 100`.
4. Phase 2: a background `vtysh` keeps adding and removing 4-way ECMP static
   routes with `zebra nexthop-group keep 1`, so zebra keeps sending
   `GR_NH_DEL`. 80 more hosts come up, one every 0.1 s. Every MAC learned by
   grout must reach zebra.

Results on 0794bf3b, Linux 7.2.9, 14 CPUs:

| run | phase 1 (zebra idle) | phase 2 (zebra deleting nexthops) |
|---|---|---|
| 1 | 0/20 missing | **4/80 missing** (529 `GR_NH_DEL`) |
| 2 | 0/20 missing | **5/80 missing** (510) |
| 3 | 0/20 missing | **4/80 missing** (477) |
| 4 | 0/20 missing | **3/80 missing** (452) |
| 5 | 0/20 missing | **2/80 missing** (468) |

```
learned by grout, unknown to zebra: 02:00:5e:10:00:14
learned by grout, unknown to zebra: 02:00:5e:10:00:15
learned by grout, unknown to zebra: 02:00:5e:10:00:1d
learned by grout, unknown to zebra: 02:00:5e:10:00:24
hosts=80 missing_in_zebra=4
fail: MACs missing in zebra while it was deleting nexthops
```

grout did emit `GR_EVENT_FDB_ADD` for every missing MAC; only zebra's copy was
dropped. For all 18 MACs missing across the 5 runs, the smoke harness's own
`grcli events` subscriber (separate process, `suppress_self_events = false`)
logged `fdb add: bridge=br100 <mac> iface=p1 learn`, while zebra's log has no
`grout_macfdb_change: add` for it.

<details>
<summary><code>smoke/evpn_fdb_event_lost_frr_test.sh</code></summary>

```bash
#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause

# Every MAC that grout learns on a bridge member of an L2 VNI must reach zebra
# as a local EVPN MAC, also while zebra is deleting nexthops.
#
# Hosts are simulated with macvlan interfaces stacked on the kernel side of
# the bridge member: bringing one up makes the kernel send IPv6 DAD/MLD
# frames from its MAC, which grout learns.
#
# 1. Control: bring up hosts while zebra is idle. All of them must show up
#    in "show evpn mac vni 100".
# 2. Bring up hosts while zebra adds and removes static routes, which makes
#    it send GR_NH_DEL requests to grout. All of them must show up as well.

. $(dirname $0)/_init_frr.sh

create_interface p0
set_ip_address p0 172.16.0.2/24

vtysh <<-EOF
configure terminal
zebra nexthop-group keep 1
router bgp 65000
 bgp router-id 172.16.0.2
 no bgp default ipv4-unicast
 address-family l2vpn evpn
  advertise-all-vni
 exit-address-family
exit
EOF

# Zebra ignores VNI and FDB notifications until advertise-all-vni has taken
# effect (https://github.com/FRRouting/frr/issues/21190).
attempts=0
while ! vtysh -c "show evpn" | grep -q "L2 VNIs"; do
	[ "$attempts" -ge 10 ] && fail "EVPN not enabled in zebra"
	sleep 1
	attempts=$((attempts + 1))
done

grcli interface add bridge br100
grcli interface add vxlan vxlan100 vni 100 local 172.16.0.2 domain br100

attempts=0
while ! vtysh -c "show evpn vni 100" | grep -q "VNI: 100"; do
	[ "$attempts" -ge 10 ] && fail "zebra did not learn VNI 100"
	sleep 1
	attempts=$((attempts + 1))
done

create_interface p1 domain br100
netns_add hosts
move_to_netns x-p1 hosts

# hosts_up <first> <count> [<interval>]: bring up <count> hosts with MAC
# 02:00:5e:10:00:<n>, one every <interval> seconds.
hosts_up() {
	local first="$1" count="$2" interval="${3:-0}" n
	for n in $(seq "$first" $((first + count - 1))); do
		ip -n hosts link add link x-p1 name h$n \
			address $(printf "02:00:5e:10:00:%02x" "$n") type macvlan mode private
		ip -n hosts link set h$n up
		sleep "$interval"
	done
}

# check_hosts <first> <count>: every host MAC learned by grout must be a
# local MAC in zebra.
check_hosts() {
	local first="$1" count="$2" n mac missing=0
	# leave time for DAD/MLD frames and for zebra to process the events
	sleep 3
	local grout_macs zebra_macs
	grout_macs=$(grcli -j fdb show iface p1 | jq -r '.[].mac')
	zebra_macs=$(vtysh -c "show evpn mac vni 100" | awk '$2 == "local" {print $1}')
	for n in $(seq "$first" $((first + count - 1))); do
		mac=$(printf "02:00:5e:10:00:%02x" "$n")
		grep -qx "$mac" <<< "$grout_macs" || fail "grout did not learn $mac"
		if ! grep -qx "$mac" <<< "$zebra_macs"; then
			echo "learned by grout, unknown to zebra: $mac"
			missing=$((missing + 1))
		fi
	done
	echo "hosts=$count missing_in_zebra=$missing"
	[ "$missing" -eq 0 ]
}

# Phase 1: zebra idle.
hosts_up 0 20
check_hosts 0 20 || fail "MACs missing in zebra while it was idle"

# Phase 2: zebra continuously adds and removes ECMP routes through rotating
# gateways. With "nexthop-group keep 1", each removed route frees its nexthops
# and nexthop group, which zebra deletes from grout with GR_NH_DEL.
{
	echo "configure terminal"
	i=0
	while :; do
		dst=198.51.100.$((i % 250))/32
		for g in 0 1 2 3; do
			echo "ip route $dst 172.16.0.$((10 + (i * 4 + g) % 200))"
		done
		for g in 0 1 2 3; do
			echo "no ip route $dst 172.16.0.$((10 + (i * 4 + g) % 200))"
		done
		i=$((i + 1))
	done
} | vtysh >/dev/null 2>&1 &
churn_pid=$!

sleep 3
hosts_up 20 80 0.1
kill $churn_pid
wait $churn_pid 2>/dev/null || :

check_hosts 20 80 || fail "MACs missing in zebra while it was deleting nexthops"
```

</details>

### Stronger variant: API client

How often the shell test loses MACs depends on how fast `vtysh` can make
zebra delete nexthops (~40–50/s). `smoke/fdb_event_watch.c` (attached patch,
built like `fib_inject`) hits the same race directly through the API: one
process subscribes to `GR_EVENT_FDB_ADD` with `suppress_self_events = true`
and loops `GR_NH_ADD`/`GR_NH_DEL` on a second socket, while 100 unique source
MACs are injected on a bridge port with `AF_PACKET`.

| grout | control (no requests) | with `GR_NH_ADD`/`GR_NH_DEL` |
|---|---|---|
| 0794bf3b, 3 runs | 100/100 notified | **3, 1 and 10 out of 100 notified** |
| 0794bf3b + fix below, 5 runs | 100/100 notified | 100/100 notified |

## How it was found

OpenPERouter e2e CI: grout + FRR, EVPN L2VNI, symmetric routing through an
SRv6 L3VPN, 3 nodes. A pod (192.171.24.3 / `f6:ce:79:73:0c:48`) could not be
reached from a remote host.

On the node hosting the pod:

- `grcli fdb show`: `br-pe-110  f6:ce:79:73:0c:48  pe-110  learn  2`.
- `grcli nexthop show`:
  `red learn br-pe-110 L3 family=ipv4 addr=192.171.24.3 state=reachable mac=f6:ce:79:73:0c:48`.
- zebra's log has no `GR_EVENT_FDB_ADD` for that MAC; the last FDB event it
  received was 16 s earlier. The first event about 192.171.24.3 is a
  `GR_EVENT_NEXTHOP_UPDATE`, with no `GR_EVENT_NEXTHOP_NEW` before it. The line
  right before it is zebra's own `GR_NH_DEL`/`GR_NH_ADD` pair for its
  `169.254.0.1` rmac nexthop, which zebra re-installs every ~10 s:

  ```
  10:08:33.343 ZEBRA: GROUT: grout_client_send_recv: GR_NH_DEL: success
  10:08:33.360 ZEBRA: GROUT: grout_client_send_recv: GR_NH_ADD: success
  10:08:34.179 ZEBRA: GROUT: zebra_read_notifications: GR_EVENT_NEXTHOP_UPDATE
  10:08:34.179 ZEBRA: GROUT: grout_neigh_notify: add neigh iface=8 192.171.24.3 f6:ce:79:73:0c:48
  ```

- zebra ignores the ~80 subsequent neighbor updates, since it has no local MAC
  to attach them to, and bgpd never originates the type-2 route.
- On the other nodes, the neighbor 192.171.24.3 is `state=failed`. Return
  traffic that the remote PE sends to them through ECMP is dropped.

Earlier in the same run, another pod with the same IP on the same node got its
`GR_EVENT_FDB_ADD` and `GR_EVENT_NEXTHOP_NEW` normally.

## Root cause

1. `fdb_learn()` runs on a datapath worker (`modules/l2/datapath/bridge_input.c:72`)
   and calls `event_push(GR_EVENT_FDB_ADD, fdb)` (`modules/l2/control/fdb.c:137`).
   From a worker thread, `event_push()` defers the notification through the
   control queue (`main/event.c:58`).
2. The control plane thread processes API requests with `cur_req_pid` set to
   the requesting client's PID (`main/api.c:415-417`).
3. Some handlers drain the control queue synchronously, e.g.
   `nexthop_destroy()` → `control_queue_drain(GR_EVENT_NEXTHOP_DELETE, nh)`
   (`modules/infra/control/nexthop.c:510`, reached from `GR_NH_DEL`) and
   `iface_destroy()` → `control_queue_drain(GR_EVENT_IFACE_REMOVE, iface)`
   (`modules/infra/control/iface.c:725`). `nexthop_destroy()` calls
   `rte_rcu_qsbr_synchronize()` first, which keeps the window open while the
   workers keep queueing items.
4. The drained `notify_subscribers()` → `api_send_notifications()` skips
   every subscriber whose `pid == cur_req_pid` and that set
   `suppress_self_events` (`main/api.c:126,132`). The datapath event is thus
   attributed to the client whose request happened to trigger the drain.
5. zebra subscribes with `suppress_self_events = true` to `GR_EVENT_FDB_ADD`
   (`frr/zebra_dplane_grout.c:681`) and `GR_EVENT_NEXTHOP_NEW`
   (`frr/zebra_dplane_grout.c:733`), among others. All its sockets share one PID.
6. `fdb_learn()` emits `GR_EVENT_FDB_ADD` only when it creates the entry.
   Further frames only refresh `last_seen`, so nothing re-announces the MAC
   unless it ages out.

The same applies to any event emitted from a control queue callback during the
drain, e.g. ARP/NDP learning → `GR_EVENT_NEXTHOP_NEW`.

## Proposed fix

Control queue items come from datapath workers, never from the API client
whose request triggers the drain, so clear `cur_req_pid` while draining. The
regular `control_queue_poll()` from the event loop already runs with
`cur_req_pid == 0`.

```diff
diff --git a/main/api.c b/main/api.c
index fd8fd9fb..feb2d3f9 100644
--- a/main/api.c
+++ b/main/api.c
@@ -94,6 +94,12 @@ void api_disconnect_register(api_disconnect_cb cb) {
 	vec_add(disconnect_cbs, cb);
 }
 
+pid_t api_req_pid_swap(pid_t pid) {
+	pid_t old = cur_req_pid;
+	cur_req_pid = pid;
+	return old;
+}
+
 void api_send_notifications(uint32_t ev_type, const void *obj) {
 	struct subscription *ev_subs = NULL;
 	struct module_subscribers *subs;
diff --git a/main/api.h b/main/api.h
index 8ff80113..0cec23ee 100644
--- a/main/api.h
+++ b/main/api.h
@@ -5,6 +5,13 @@
 
 #include <event2/event.h>
 
+#include <sys/types.h>
+
 int api_socket_start(struct event_base *);
 void api_socket_stop(struct event_base *);
 void api_send_notifications(uint32_t ev_type, const void *obj);
+
+// Replace the PID of the API client whose request is being processed and
+// return the previous one. Events emitted while it is set are suppressed for
+// subscribers of that client that requested suppress_self_events.
+pid_t api_req_pid_swap(pid_t pid);
diff --git a/main/control_queue.c b/main/control_queue.c
index 6bb5fdb5..ba075e1a 100644
--- a/main/control_queue.c
+++ b/main/control_queue.c
@@ -1,6 +1,7 @@
 // SPDX-License-Identifier: BSD-3-Clause
 // Copyright (c) 2024 Christophe Fontaine
 
+#include "api.h"
 #include "control_queue.h"
 #include "log.h"
 #include "metrics.h"
@@ -100,7 +101,12 @@ static void *sem_wait_to_event(void *) {
 
 void control_queue_drain(uint32_t event, const void *obj) {
 	struct control_queue_drain drain = {event, obj};
+	// Queued items were pushed by datapath workers. They are not caused by
+	// the API request that may be triggering this drain, so their events
+	// must not be suppressed for the requesting client.
+	pid_t req_pid = api_req_pid_swap(0);
 	control_queue_poll(0, 0, &drain);
+	api_req_pid_swap(req_pid);
 }
 
 METRIC_COUNTER(m_cqueue_fail, "control_queue_fail", "Total number of enqueue failures");
```

The fix was checked with the API-client reproducer: 5 out of 5 runs pass, with
100/100 notified while ~1,700–2,100 nexthop add/del cycles ran during each test.
It has not been run with the shell test yet.

Possible hardening, independent of the fix:

- `event_push()` drops the event without a trace when `control_queue_push()`
  fails (`XXX: add error stat`). A counter would make such losses visible.
- The FRR plugin only does a full FDB sync (`grout_sync_fdb`) when it connects,
  so a lost FDB event is never recovered.
