#!/bin/bash


. $(dirname $0)/_init.sh



grcli interface add port p0 devargs "net_tap1,iface=x-p0" 
grcli interface add port p1 devargs "net_tap1,iface=x-p1" 

ip -d link

