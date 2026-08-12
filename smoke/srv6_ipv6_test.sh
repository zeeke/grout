#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025 Olivier Gournet

. $(dirname $0)/_init.sh

#
# IPv6-in-SRv6 encapsulation test
#
# Verify the outer IPv6 payload length when grout encapsulates IPv6
# traffic in SRv6.  The inner IPv6 payload_len excludes the 40-byte
# header (unlike IPv4 total_length), so the encap code must add
# sizeof(rte_ipv6_hdr).  A wrong outer payload length causes the
# receiving kernel to truncate the inner packet.
#
#            n0 (netns)                grout                 n1 (netns)
#       192.168.61.2/24            p0 ---- p1           192.168.60.1/24
#       fd00:61::2/64             /          \           fd00:60::1 (lo)
#              \                 / fd00:61::1  \              /
#          x-p0 ================    fd00:102::1  ============== x-p1
#                                               fd00:102::/32  fd00:102::2
#
# IPv4-in-SRv6 (establishes connectivity):
#  n0 pings 192.168.60.1, grout encaps, n1 decaps with End.DX4
#
# IPv6-in-SRv6 (the actual test):
#  n0 pings fd00:60::1, grout encaps, n1 decaps with End.DT6
#

port_add p0
port_add p1
grcli address add fd00:102::1/32 iface p1
grcli address add 192.168.61.1/24 iface p0

for n in 0 1; do
	p=x-p$n
	ns=n$n
	netns_add $ns
	move_to_netns $p $ns
done
ip -n n0 addr add 192.168.61.2/24 dev x-p0
ip -n n1 addr add fd00:102::2/32 dev x-p1

ip netns exec n1 sysctl -w net.ipv6.conf.x-p1.seg6_enabled=1
ip netns exec n1 sysctl -w net.ipv6.conf.x-p1.forwarding=1

# IPv4-in-SRv6 round trip (same as srv6_test.sh)
ip -n n0 route add default via 192.168.61.1 dev x-p0
grcli nexthop add srv6 seglist fd00:202:200:: id 42
grcli route add 192.168.0.0/16 via id 42
grcli route add fd00:202::/32 via fd00:102::2
ip -n n1 -6 route add fd00:202:200:: encap seg6local action End.DX4 nh4 192.168.60.1 dev x-p1
ip -n n1 addr add 192.168.60.1/24 dev x-p1
ip -n n1 route add 192.168.61.0/24 encap seg6 mode encap segs fd00:202:100:: dev x-p1
ip -n n1 -6 route add fd00:202::/32 via fd00:102::1 dev x-p1
grcli nexthop add srv6-local behavior end.dt4 id 666
grcli route add fd00:202:100::/48 via id 666

ip netns exec n0 ping -i0.01 -c3 -n 192.168.60.1

# IPv6-in-SRv6
grcli address add fd00:61::1/64 iface p0
ip -n n0 addr add fd00:61::2/64 dev x-p0
ip -n n0 -6 route add fd00:60::/64 via fd00:61::1 dev x-p0

grcli nexthop add srv6 seglist fd00:202:600:: id 60
grcli route add fd00:60::/64 via id 60

# End.DT6 in a VRF: the kernel decaps and does an input route lookup
# in the VRF table, which correctly finds the local address.
# End.DX6 with nh6 :: uses ip6_route_output() which does NOT find
# local routes (kernel limitation), so End.DT6 is required here.
ip netns exec n1 sysctl -qw net.vrf.strict_mode=1
ip -n n1 link add vrf10 type vrf table 10
ip -n n1 link set vrf10 up
ip -n n1 -6 route add fd00:202:600:: encap seg6local action End.DT6 vrftable 10 dev x-p1
ip -n n1 addr add fd00:60::1/128 dev vrf10
ip -n n1 -6 route add fd00:61::/64 via fd00:102::1 dev x-p1 table 10

ip netns exec n0 ping6 -i0.01 -c3 -n fd00:60::1
