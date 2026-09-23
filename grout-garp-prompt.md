You are working in the DPDK/grout repository (https://github.com/DPDK/grout). The goal is to
document, with a failing smoke test and an upstream issue, a gap in grout's IPv4 neighbor
learning on bridges. Read CONTRIBUTING.md, smoke/_init.sh, smoke/_init_frr.sh,
smoke/bridge_neigh_suppress_test.sh and smoke/evpn_neigh_suppress_frr_test.sh before writing
anything.

## Background

OpenPERouter (github.com/openperouter/openperouter) uses grout as a datapath for EVPN L2VNIs.
For a "disconnected" L2VNI it creates a grout bridge with NO IP address, a vxlan member and a
port towards the hosts, roughly:

    grcli interface add bridge br-pe-300 flood learn neigh_suppress neigh_snoop on
    grcli interface add vxlan vni300 vni 300 local <vtep> domain br-pe-300
    grcli interface add port pe-300 ... domain br-pe-300

FRR runs with `advertise-all-vni`. Pods on two nodes are expected to show up in EVPN as type-2
MAC+IP routes (RFC 7432) without sending any traffic, as they do with the Linux kernel
datapath.

Observed with grout v0.17.1. The code paths below are unchanged on main (v0.18.0, e36e550)
apart from the strong-host-model check added to arp_input_request.c:

- FRR advertises MAC-only type-2 routes for the pods, and MAC+IP routes only for their IPv6
  link-local addresses. There is no MAC+IP route for their IPv4 addresses.
- `grcli nexthop show` has no IPv4 neighbor on the bridge, but does have the pods' fe80::
  neighbors (origin learn locally, `flags=remote neigh` on the other node).
- `grcli stats show` on each node: `arp_input_request` 2 -> `arp_input_request_drop` 2 (and
  1 -> 1 on the other node). `arp_input_reply` never ran.

Root cause, as read from the source (verify it yourself before relying on it):

1. The pod's CNI sends a gratuitous ARP (sender IP == target IP) when the interface comes up.
   It is broadcast, so bridge_input.c sends it to bridge_neigh_suppress / bridge_flood, and
   the copy delivered to the bridge's L3 reaches arp_input_request.
2. modules/ip/datapath/arp_input_request.c drops every request whose target IP is unknown or
   not GR_NH_F_LOCAL. The bridge has no address, so the gratuitous ARP is dropped and the
   sender is never learned. GR_IFACE_F_NEIGH_SNOOP is not checked on this path.
3. modules/ip/datapath/arp_input_reply.c:40 is the only place that honors
   GR_IFACE_F_NEIGH_SNOOP, but ARP replies between hosts are unicast. bridge_input.c resolves
   them via the FDB and forwards them port to port, so they never reach the bridge's L3.
4. arp_probe_input_cb (modules/ip/control/nexthop.c) creates or refreshes the nexthop from
   arp_sip/arp_sha, and replies to a request only when the target is a local address exposed on
   that interface. Routing a gratuitous ARP to it would therefore learn the neighbor without
   sending a wrong reply.

For comparison, Linux creates a neighbor entry from a gratuitous ARP on a bridge with no IPv4
address when net.ipv4.conf.*.arp_accept=1. OpenPERouter sets that sysctl, and that is how the
kernel datapath gets the IP/MAC binding FRR advertises. IPv6 works on grout only because the
bridge gets an fe80:: address, so NDP exchanges with the bridge itself reach local handlers.
Note that smoke/evpn_neigh_suppress_frr_test.sh passes only because its hosts ping a gateway
address configured on the bridge. It never covers a bridge without an address.

## Task 1: smoke test

Write a smoke test that fails on current main and would pass once grout learns the sender of
a gratuitous ARP on a bridge with neigh_snoop enabled.

- Prefer a new, non-FRR test modeled on smoke/bridge_neigh_suppress_test.sh (for example
  smoke/bridge_neigh_snoop_test.sh; follow the naming of existing tests). Bridge with
  neigh_snoop on, NO IP address on the bridge, two ports in two host netns. From one host send
  a gratuitous ARP (`arping -U`, and also the reply form `arping -A` if you think it is
  worth covering) and assert, with a bounded retry, that grout learned that IP with that host's
  MAC on the bridge (use `grcli nexthop show`, or its JSON form if one exists).
- Include a control check: with neigh_snoop off, the gratuitous ARP must not create a learned
  neighbor. This keeps the expected behavior tied to the flag.
- If you judge it valuable, add an EVPN end-to-end variant, either extending
  smoke/evpn_neigh_suppress_frr_test.sh or as a separate *_frr_test.sh. There, the grout bridge
  has no address, and the peer's `show evpn arp-cache vni <n> json` must show the grout-side
  host as a remote entry with no host traffic other than the gratuitous ARP. Keep it separate
  from the plain test so a failure points at one layer.
- Match the style of the existing smoke tests: license header, ASCII topology diagram, the
  helpers from _init.sh, and a failure path that dumps useful state (nexthop show, stats) before
  calling fail.
- Build grout and run your test (see GNUmakefile; `SMOKE_MATCH=` selects tests). Confirm it
  fails for the reason above, for example by checking that arp_input_request_drop increments in
  `grcli stats show`. The smoke tests need root, network namespaces and possibly hugepages.
  If this environment can't run them, say so plainly and report the test as not run. Do not
  claim a pass or fail you did not observe.

Do not change grout's datapath or control-plane code in this session. Put the proposed fix in
the issue instead.

## Task 2: issue body

Write the body of an upstream issue to `issue-neigh-snoop-garp.md` at the repository root (do
not commit it). Include:

- A one-line title suggestion on the first line.
- Summary: on a bridge without an IPv4 address, grout never learns local hosts' IPv4 neighbors,
  even with neigh_snoop enabled, so FRR EVPN never gets MAC+IP type-2 routes for them.
- Versions affected: v0.17.1 and main (v0.18.0). Say which of these you checked yourself.
- Reproduction: point at the smoke test from Task 1, plus a minimal grcli/arping sequence.
- Observed vs expected. Expected behavior follows Linux arp_accept: learn from gratuitous ARP.
- Root cause with file and line references on main.
- Proposed fix. In arp_input_request, when the receiving interface has GR_IFACE_F_NEIGH_SNOOP
  and the request is gratuitous (arp_sip == arp_tip), send it to control with
  arp_probe_input_cb instead of dropping it. Mention as an open question whether snooping
  should also learn from non-gratuitous requests and from unicast replies (bridge_input.c would
  need to copy them to the bridge), and the trade-offs you see.
- Impact: EVPN deployments where the bridge is a pure L2 domain (no SVI/gateway address), such
  as OpenPERouter disconnected L2VNIs. Remote VTEPs get no MAC+IP routes, so there is no
  remote ARP suppression and anything relying on type-2 MAC+IP breaks.
- Keep it factual. Mark anything you inferred but did not verify as such.

## Conventions and limits

- Follow CONTRIBUTING.md for commit format. Commits need a Signed-off-by from the human author;
  do not invent one. If you cannot sign off, leave the change uncommitted and say so.
- Do not push, open a pull request, or open the GitHub issue. Stop after writing the test and
  the issue file, and summarize: files changed, how you ran the test, and the exact result.
