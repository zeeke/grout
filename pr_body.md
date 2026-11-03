




GROUT_IMAGE=quay.io/apanatto/grout:0.19.3-garp-fix bash devtools/evpn-vip-move-repro.sh > reproducer_fix.log;
GROUT_IMAGE=quay.io/grout/grout:0.19.3 bash devtools/evpn-vip-move-repro.sh > reproducer.log;

