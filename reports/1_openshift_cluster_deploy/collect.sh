#!/usr/bin/env bash
# Collects the evidence for the API VIP / EVPN stale-MAC problem (deploy 33).
# Usage: ./collect.sh [outdir]   (run from deploys/33a_vip_mac)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
RC="$HERE/../../remote-cmd.sh"
OUT=${1:-$HERE/data}
mkdir -p "$OUT"
VIP=192.168.110.10

run() { # node, label, command
    local node=$1 label=$2; shift 2
    { echo "\$ $*"; timeout 60 "$RC" "$node" "$*"; echo; } >> "$OUT/$node.$label.txt"
}

for n in master-0 master-1 master-2 worker-0 worker-1; do
    rm -f "$OUT/$n".*.txt
    run $n host      'date -u; hostname; uptime'
    run $n host      'ip -br addr'
    run $n host      "ip -4 addr | grep -c $VIP || true"
    run $n host      'ip neigh show'
    run $n reach     "ping -c3 -W1 $VIP | tail -2"
    run $n reach     "for ip in 192.168.110.2 192.168.110.3 192.168.110.4; do echo -n \"\$ip: \"; ping -c1 -W1 \$ip >/dev/null && echo ok || echo FAIL; done"
    run $n reach     "curl -sk -m5 -o /dev/null -w 'VIP      $VIP:6443/readyz -> %{http_code}\n' https://$VIP:6443/readyz"
    run $n reach     "curl -sk -m5 -o /dev/null -w 'master-2 192.168.110.4:6443/readyz -> %{http_code}\n' https://192.168.110.4:6443/readyz"
    run $n evpn      'podman exec frr vtysh -c "show evpn arp-cache vni all"'
    run $n evpn      'podman exec frr vtysh -c "show evpn mac vni all"'
    run $n evpn      "podman exec frr vtysh -c 'show evpn arp-cache vni 210 ip $VIP'"
    run $n evpn      'podman exec frr vtysh -c "show bgp l2vpn evpn route type macip"'
    run $n grout     "podman exec grout grcli nexthop show | grep -E 'VRF|br-pe-210'"
    run $n grout     'podman exec grout grcli nexthop show internal'
    run $n grout     'podman exec grout grcli fdb show'
    run $n grout     'podman exec grout grcli mac show'
    run $n grout     'podman exec grout grcli nexthop config show'
    run $n grout     'podman exec grout grcli interface show'
    run $n grout     'podman exec grout grcli --version; podman exec frr vtysh -c "show version" | head -1'
done

# keepalived history: who held the VIP and when
for n in master-0 master-1 master-2; do
    run $n keepalived 'crictl logs $(crictl ps -q --name "^keepalived$") 2>&1 | grep -vE "Printing (parent|VRRP) data|Interface [0-9a-f]+ (deleted|added)"'
done

# ARP probe from a third node: who answers for the VIP, and with which MAC
run master-1 arping "arping -c3 -I br-ex $VIP"
run worker-0 arping "arping -c3 -I enp8s0 $VIP"

# installer side
run master-0 installer 'podman logs --tail 40 wait-for-ceo 2>&1'
run master-0 installer 'podman logs --since 30m assisted-installer 2>&1 | tail -40'
run master-0 installer "podman logs service 2>&1 | grep -oE 'Host [^ ]+: updated status from [a-z-]+ to [a-z-]+' | tail -30"
