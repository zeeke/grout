# Bug: SRv6 encapsulation sets wrong outer IPv6 Payload Length for IPv6 inner packets

## Summary

When grout SRv6-encapsulates an **IPv6** inner packet, the outer IPv6 header's
Payload Length is 40 bytes too small. This makes IPv6-in-SRv6 completely broken
while IPv4-in-SRv6 works fine.

## Root cause

In `modules/srv6/datapath/srv6_output.c`, the `srv6_output_process` function
computes `plen` (which becomes the outer IPv6 Payload Length) from the inner
packet's length field. The IPv4 and IPv6 paths use different semantics:

```c
// Line 73 — IPv4 path (CORRECT):
plen = rte_be_to_cpu_16(inner_ip4->total_length);
//   IPv4 total_length INCLUDES the 20-byte IPv4 header → correct

// Line 87 — IPv6 path (BUG):
plen = rte_be_to_cpu_16(inner_ip6->payload_len);
//   IPv6 payload_len EXCLUDES the 40-byte IPv6 header → 40 bytes too small
```

Later, `plen += optlen` adds the SRH size (line 130), and the result is stored
as the outer IPv6 Payload Length via `ip6_set_fields()` (lines 142/150).

For an IPv6 inner packet with 40 bytes of TCP payload:

| Component         | Correct value | What grout computes |
|-------------------|---------------|---------------------|
| SRH               | 24            | 24                  |
| Inner IPv6 header | 40            | **0 (missing!)**    |
| Inner TCP payload | 40            | 40                  |
| **Outer Payload Length** | **104** | **64**              |

The receiving end sees `[header+payload length 80 > length 40] (invalid)` —
after stripping the 24-byte SRH from the 64-byte payload, only 40 bytes remain
for the inner packet, but the inner IPv6 header alone needs 40 bytes, leaving
zero bytes for TCP. The packet is truncated and unusable.

## Fix

Line 87 in `modules/srv6/datapath/srv6_output.c`:

```c
// Before (bug):
plen = rte_be_to_cpu_16(inner_ip6->payload_len);

// After (fix):
plen = rte_be_to_cpu_16(inner_ip6->payload_len) + sizeof(*inner_ip6);
```

This makes `plen` represent the full inner packet length (header + payload),
matching the semantics of the IPv4 path where `total_length` already includes
the header.

## Reproducing with a smoke test

Write a smoke test (following the patterns in `smoke/srv6_test.sh`) that
SRv6-encapsulates an **IPv6** inner packet through grout. The existing SRv6
smoke tests only exercise IPv4-in-SRv6 (End.DX4 / End.DT4), which masks this
bug.

### What the test should do

The topology mirrors `srv6_test.sh` but uses IPv6 on the client side:

```
  n0 (IPv6 client)          grout           n1 (IPv6 server + SRv6 endpoint)
  x-p0 ←————————→ p0 ‹grout› p1 ←————————→ x-p1
  IPv6                    SRv6                IPv6
```

1. **Client side (n0):** has an IPv6 address (e.g. `fd00:61::2/64`) and a
   default route via grout.

2. **Grout encap:** receives the IPv6 packet on p0, matches a route, and
   SRv6-encapsulates it toward a SID on n1 (e.g. `fd00:202:200::`).

3. **Remote side (n1):** has `seg6_enabled=1`, an `End.DX6` seg6local route
   that decapsulates and delivers to a local IPv6 address
   (e.g. `fd00:60::1/64`), and a reverse SRv6 encap route back toward grout.

4. **Grout decap:** has an `End.DT6` (or `End.DT46`) local SID that
   decapsulates the return packet and delivers it back to n0.

5. **Test assertion:** `ping6` from n0 to the server address on n1 succeeds.

### Key points

- Use `End.DX6` on the Linux side (n1) for IPv6 decap, analogous to how
  `srv6_test.sh` uses `End.DX4` for IPv4.
- Use `end.dt6` or `end.dt46` on the grout side for the return path.
- The ping will fail (timeout) without the fix because the outer Payload
  Length is 40 bytes short, causing the decapsulating end to see a truncated
  inner packet.
- With the one-line fix applied, the ping succeeds.

### Packet-level evidence from production

tcpdump on the SRv6 tunnel interface (leaf) shows the bug clearly:

```
# Incoming at leaf — outer payload_len=64 but inner needs 80 bytes:
eth1 In (hlim 253, next-header Routing (43) payload length: 64)
  2001:db8:11::4 > fd00:0:10:e001::
  RT6 (len=2, type=4, segleft=0, ...)
  [header+payload length 80 > length 40] (invalid)
  (flowlabel 0x72111, hlim 62, next-header TCP (6) payload length: 40)
  2001:db8:1::3 > 2001:db8:170:20::2: [|tcp]

# After decap, forwarded to host — still truncated:
ethred Out (length 60)
  [header+payload length 80 > length 40] (invalid)
  2001:db8:1::3 > 2001:db8:170:20::2: [|tcp]

# At the host — 40 bytes missing, garbled:
In (length 56) truncated-ip6 - 40 bytes missing!
  (next-header TCP (6) payload length: 40)
  0.1.0.0 > 0.0.0.0: [|tcp]
```

The 40 missing bytes = `sizeof(struct rte_ipv6_hdr)` — exactly the inner IPv6
header that was not accounted for in the outer Payload Length.
