#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Red Hat, Inc.

trace_enable=false
grout_verbose_level=0

. $(dirname $0)/_init.sh

rss_kb() {
	ps -o rss= --pid "$grout_pid"
}

rss_after_start=$(rss_kb)
echo "RSS after start:              ${rss_after_start} kB"

grcli interface add port p4 devargs net_null2,no-rx=1 qsize 64
rss_after_port=$(rss_kb)
echo "RSS after adding port:        ${rss_after_port} kB"

grcli interface add port p5 devargs net_null3,no-rx=1 qsize 64
rss_after_port=$(rss_kb)
echo "RSS after adding 2nd port:    ${rss_after_port} kB"

grcli interface add vrf memorytestvrf
rss_after_vrf=$(rss_kb)
echo "RSS after adding VRF:         ${rss_after_vrf} kB"

grcli interface add port p6 devargs net_null4,no-rx=1 qsize 64 vrf memorytestvrf
rss_after_port=$(rss_kb)
echo "RSS after adding port in vrf: ${rss_after_port} kB"
