bridge: learn gratuitous arp senders with neigh_snoop

## Summary

On a bridge with no IPv4 address, grout does not learn local hosts' IPv4
neighbors from gratuitous ARP, even with `neigh_snoop` enabled. FRR therefore
does not advertise MAC+IP EVPN Type-2 routes for those IPv4 addresses.

This affects pure L2 EVPN VNIs such as OpenPERouter's disconnected L2VNIs,
where the bridge has a VXLAN member and host-facing ports but no SVI/gateway
address. OpenPERouter configures Linux `arp_accept` so the kernel learns these
bindings from gratuitous ARP.

## Versions affected

- `v0.17.1`: reported by the OpenPERouter deployment; not independently run
  during this investigation.
- `main` / `v0.18.0` (`e36e5502`): source-checked and reproduced with the smoke
  test below on this checkout.

## Reproduction

Run `smoke/bridge_neigh_snoop_test.sh`. It creates a grout bridge with no IPv4
address, two TAP ports in separate host namespaces, enables `neigh_snoop`, and
checks learning from gratuitous ARP request and reply forms.

The core sequence is:

```sh
grcli interface add bridge br0 neigh_snoop on
grcli interface add port p0 devargs net_tap0,iface=x-p0 domain br0
grcli interface add port p1 devargs net_tap1,iface=x-p1 domain br0
# Move x-p0 to host-a and assign 10.0.0.2/24; leave br0 without an IPv4 address.
ip netns exec host-a arping -U -c1 -w1 -I x-p0 10.0.0.2
grcli nexthop show
grcli stats show software
```

The smoke test also sends the gratuitous ARP reply form (`arping -A`) from the
second host.

## Observed and expected

Observed on `main` / `v0.18.0`: with snooping enabled, the `-U` gratuitous ARP
request is copied to the bridge's L3 path and dropped by `arp_input_request`;
the expected learned IPv4 nexthop is absent. In the local run,
`arp_input_request_drop` incremented for this request. The test stops at that
failure, so its `-A` case was not reached.

The OpenPERouter report also observes MAC-only EVPN Type-2 routes for pods but
no MAC+IP route for their IPv4 addresses. That report describes IPv6 link-local
MAC+IP routes and learned `fe80::` neighbors on grout; it attributes those to
the bridge's IPv6 link-local address. Those EVPN observations were not
independently reproduced in this plain smoke test.

Expected: with `neigh_snoop` enabled, grout learns the sender IPv4/MAC binding
from gratuitous ARP on the bridge even when the bridge has no IPv4 address,
analogous to Linux with `net.ipv4.conf.*.arp_accept=1`. `grcli nexthop show`
should contain an IPv4 `origin=learn` neighbor on `br0` with the host's MAC;
FRR can then advertise the corresponding MAC+IP Type-2 route.

## Root cause

On `main` (`e36e5502`):

- `modules/l2/datapath/bridge_input.c:69-94` forwards known unicast frames
  directly to the FDB-selected port. Broadcast ARP instead reaches the flood
  path; `modules/l2/datapath/bridge_flood.c:87-92` also copies it to the bridge
  interface for L3 input.
- `modules/ip/datapath/arp_input_request.c:41-46` drops a request if its target
  IPv4 address is unknown. Lines 48-59 also drop targets that are not local or
  exposed on the receiving interface. There is no `GR_IFACE_F_NEIGH_SNOOP`
  check before these drops. In this reproduction there is no existing IPv4
  nexthop for the host address, and a gratuitous ARP request uses the sender
  IPv4 address as its target, so the target lookup misses.
- `modules/ip/datapath/arp_input_reply.c:38-44` does send replies to
  `arp_probe_input_cb` when `GR_IFACE_F_NEIGH_SNOOP` is set. However, known
  unicast host-to-host replies are forwarded port-to-port by
  `bridge_input.c:69-94`, so they do not reach the bridge's L3 path.
- `modules/ip/control/nexthop.c:154-175` creates or refreshes a learned
  nexthop from the ARP sender IPv4 address and MAC. Lines 197-202 generate an
  ARP response for request targets accepted by `addr4_exposed_on_iface`. That
  helper accepts the nexthop's owning interface, so after learning a GARP
  sender on the bridge the newly created neighbor can also look replyable. The
  response check must verify `GR_NH_F_LOCAL` before answering.

## Proposed fix

In `arp_input_request`, before its target and locality checks, check whether
the receiving interface has `GR_IFACE_F_NEIGH_SNOOP` and the request is
gratuitous (`arp_sip == arp_tip`). If so, pass it to `arp_probe_input_cb`
instead of dropping it. In the callback, only answer when the target nexthop
has `GR_NH_F_LOCAL` and is exposed on the receiving interface. Keep the
learning change scoped to gratuitous requests initially so the flag does not
implicitly learn from every ordinary ARP request.

Open question: should snooping also learn from non-gratuitous requests? That
could learn hosts that do not emit gratuitous ARP, but it would trust more
unsolicited sender claims and broaden the source of neighbor updates. Should
known unicast replies also be copied to bridge L3 for snooping? That would
observe replies that are currently forwarded directly between ports, at the
cost of extra packet copies and control-plane processing on the bridge path.

## Impact

In an EVPN bridge that is a pure L2 domain with no SVI/gateway address, local
IPv4 hosts learned only through gratuitous ARP have no grout IPv4 neighbor
entry and therefore no MAC+IP Type-2 advertisement. Remote VTEPs get no
corresponding IPv4 ARP entry for suppression. Deployments or services relying
on those MAC+IP routes cannot use them for remote ARP suppression or other
MAC+IP route behavior.
