# Low-memory mode (`-L` / `--low-memory`)

When grout is started with `-L`, several internal data structures are
allocated with smaller defaults. This reduces hugepage consumption at
the cost of supporting fewer routes, nexthops, and packet buffers. It
is intended for development, testing, and small-scale lab environments
where full production capacity is not needed.

## Parameters

| Parameter | File | Default | Low-memory | Approx. savings |
|---|---|---|---|---|
| mempool size | `modules/infra/control/mempool.c` | 65535 | 8191 | ~123 MB per pool |
| nexthop max count | `modules/infra/control/nexthop.c` | 131072 | 16384 | ~15 MB |
| IPv4 max routes | `modules/ip/control/route.c` | 65536 | 1024 | varies per VRF |
| IPv6 max routes | `modules/ip6/control/route.c` | 65536 | 1024 | varies per VRF |

### mempool size

Initial number of packet buffers (mbufs) per mempool. One mempool is
created per port/NUMA combination. Each mbuf is approximately 2240
bytes (128-byte rte_mbuf header + 64-byte private data + 2048-byte
data buffer). This is by far the largest consumer of hugepage memory:
a single pool at the default size uses ~140 MB while the low-memory
size uses ~17 MB. The pool grows automatically if a single reservation
exceeds 1/4 of the current size.

### nexthop max count

Maximum number of nexthop entries across all VRFs. Each nexthop
represents a destination reachable via a specific interface and gateway
(ARP/NDP neighbor). Each entry is 128 bytes (two cache lines). The
pool is allocated once at startup. At 131072 entries it uses ~16 MB;
at 16384 it uses ~2 MB. The savings are small relative to mempools.

### IPv4 max routes

Default maximum number of IPv4 routes per VRF FIB. Controls the size
of the DIR-24-8 lookup structure and associated tbl8 groups. Fewer max
routes means a smaller FIB allocation but the VRF will reject route
insertions once full. Can be overridden per VRF via the API.

### IPv6 max routes

Default maximum number of IPv6 routes per VRF FIB. Controls the size
of the trie-based lookup structure and associated tbl8 groups (allocated
at 4x max_routes by default). Same trade-off as IPv4. Can be overridden
per VRF via the API.


╰╼ make FRR=10.6 &&  sudo INTERACTIVE=false ./smoke/memory_test.sh build_old 2>/dev/null | grep RSS  
ninja: Entering directory `build'
ninja: no work to do.
RSS after start:              356116 kB
RSS after adding port:        880812 kB
RSS after adding 2nd port:    880820 kB
RSS after adding VRF:         1142972 kB
RSS after adding port in vrf: 1142996 kB
╿ 23:45:07 github.com/DPDK/grout | memory_optimize ✘ ⇣⇡MU    
╰╼ make FRR=10.6 &&  sudo INTERACTIVE=false ./smoke/memory_test.sh build 2>/dev/null | grep RSS     
ninja: Entering directory `build'
ninja: no work to do.
RSS after start:              94460 kB
RSS after adding port:        389776 kB
RSS after adding 2nd port:    389784 kB
RSS after adding VRF:         651936 kB
RSS after adding port in vrf: 651960 kB

--- max-routes 256
-130- make FRR=10.6 &&  sudo INTERACTIVE=false ./smoke/memory_test.sh build 2>/dev/null | grep RSS 
ninja: Entering directory `build'
[3/3] Linking target grout
RSS after start:              94520 kB
RSS after adding port:        389836 kB
RSS after adding 2nd port:    389844 kB
RSS after adding VRF:         652004 kB
RSS after adding port in vrf: 652040 kB

--- next-hop 1024
╰╼ make FRR=10.6 &&  sudo INTERACTIVE=false ./smoke/memory_test.sh build 2>/dev/null | grep RSS 
ninja: Entering directory `build'
[2/2] Linking target grout
RSS after start:              90592 kB
RSS after adding port:        387672 kB
RSS after adding 2nd port:    387720 kB
RSS after adding VRF:         650004 kB
RSS after adding port in vrf: 650080 kB
