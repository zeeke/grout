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
