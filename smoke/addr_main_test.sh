#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026 Robin Jarry

. $(dirname $0)/_init.sh

port_add p0
ip route | grep "default dev main"

grcli address add 1.1.1.1/32 iface main
ip route | grep "default dev main"

grcli address del 1.1.1.1/32 iface main
ip route | grep "default dev main"
