// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2024 Robin Jarry

#pragma once

#include <gr_errno.h>

#include <arpa/inet.h>
#include <endian.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef __GROUT_MAIN__
#include <rte_ether.h>
#include <rte_ip6.h>
#else
#include <gr_net_compat.h>
#endif

// Address family enumeration.
typedef enum : uint8_t {
	GR_AF_UNSPEC = AF_UNSPEC,
	GR_AF_IP4 = AF_INET,
	GR_AF_IP6 = AF_INET6,
} addr_family_t;

// Convert address family enum to string representation.
static inline const char *gr_af_name(addr_family_t af) {
	switch (af) {
	case GR_AF_UNSPEC:
		return "unspec";
	case GR_AF_IP4:
		return "ipv4";
	case GR_AF_IP6:
		return "ipv6";
	}
	return "?";
}

// Check if address family value is valid.
static inline bool gr_af_valid(addr_family_t af) {
	switch (af) {
	case GR_AF_UNSPEC:
	case GR_AF_IP4:
	case GR_AF_IP6:
		return true;
	}
	return false;
}

// Custom printf specifiers for network addresses.

// struct rte_ether_addr *
#define ETH_F "%2p"
// ip4_addr_t *
#define IP4_F "%4p"
// struct rte_ipv6_addr *
#define IP6_F "%6p"
// struct ip4_net *
#define IP4_NET_F "%32p"
// struct ip6_net *
#define IP6_NET_F "%128p"
// Either ETH_F, IP4_F, IP6_F, IP4_NET_F or IP6_NET_F depending on the width argument
#define ADDR_F "%*p"

#define ADDR_W(family) (family == AF_INET ? 4 : (family == AF_INET6 ? 6 : 0))
#define NET_W(family) (family == AF_INET ? 32 : (family == AF_INET6 ? 128 : 0))

#define ETH_ADDR_RE "^[[:xdigit:]]{2}(:[[:xdigit:]]{2}){5}$"

#define IPV4_ATOM "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])"
#define __IPV4_RE IPV4_ATOM "(\\." IPV4_ATOM "){3}"
#define __IPV4_PREFIX_RE "/(3[0-2]|[12][0-9]|[0-9])"
#define IPV4_RE "^" __IPV4_RE "$"
#define IPV4_NET_RE "^" __IPV4_RE __IPV4_PREFIX_RE "$"

// IPv4 address type (network byte order).
typedef uint32_t ip4_addr_t;

// IPv4 network with prefix length.
struct ip4_net {
	ip4_addr_t ip;
	uint8_t prefixlen;
};

// Check if two IPv4 addresses are in the same subnet.
static inline bool ip4_addr_same_subnet(ip4_addr_t a, ip4_addr_t b, uint8_t prefixlen) {
	ip4_addr_t mask = htonl(~(UINT32_MAX >> prefixlen));
	return ((a ^ b) & mask) == 0;
}

#define IPV4_ADDR_BCAST RTE_BE32(0xffffffff)

// Check if the provided IPv4 address is multicast.
static inline bool ip4_addr_is_mcast(const ip4_addr_t ip) {
	const union {
		ip4_addr_t ip;
		uint8_t u8[4];
	} addr = {.ip = ip};
	return addr.u8[0] >= 224 && addr.u8[0] <= 239;
}

// Parse IPv4 network string (e.g. "192.168.1.0/24") into ip4_net structure.
static inline int ip4_net_parse(const char *s, struct ip4_net *net, bool zero_mask) {
	char addr[INET_ADDRSTRLEN];

	if (sscanf(s, "%15[0-9.]/%hhu%*c", addr, &net->prefixlen) != 2) {
		errno = EINVAL;
		return -1;
	}
	if (net->prefixlen > 32) {
		errno = EINVAL;
		return -1;
	}
	if (inet_pton(AF_INET, addr, &net->ip) != 1) {
		errno = EINVAL;
		return -1;
	}
	if (zero_mask) {
		// mask non network bits to zero
		net->ip &= htonl((uint32_t)(UINT64_MAX << (32 - net->prefixlen)));
	}
	return 0;
}

#define IPV6_ATOM "([A-Fa-f0-9]{1,4})"
#define __IPV6_RE "(" IPV6_ATOM "|::?){2,15}(:" IPV6_ATOM "(\\." IPV4_ATOM "){3})?"
#define __IPV6_PREFIX_RE "/(12[0-8]|1[01][0-9]|[1-9]?[0-9])"
#define IPV6_RE "^" __IPV6_RE "$"
#define IPV6_NET_RE "^" __IPV6_RE __IPV6_PREFIX_RE "$"

// IPv6 network with prefix length.
struct ip6_net {
	struct rte_ipv6_addr ip;
	uint8_t prefixlen;
};

// Parse IPv6 network string (e.g. "2001:db8::/32") into ip6_net structure.
static inline int ip6_net_parse(const char *s, struct ip6_net *net, bool zero_mask) {
	char addr[INET6_ADDRSTRLEN];

	if (sscanf(s, "%45[A-Fa-f0-9:.]/%hhu%*c", addr, &net->prefixlen) != 2) {
		errno = EINVAL;
		return -1;
	}
	if (net->prefixlen > RTE_IPV6_MAX_DEPTH) {
		errno = EINVAL;
		return -1;
	}
	if (inet_pton(AF_INET6, addr, &net->ip) != 1) {
		errno = EINVAL;
		return -1;
	}
	if (zero_mask) {
		// mask non network bits to zero
		rte_ipv6_addr_mask(&net->ip, net->prefixlen);
	}
	return 0;
}

#define IP_ANY_RE "^(" __IPV4_RE "|" __IPV6_RE ")$"
#define IP_ANY_NET_RE "^(" __IPV4_RE __IPV4_PREFIX_RE "|" __IPV6_RE __IPV6_PREFIX_RE ")$"

struct l3_addr {
	addr_family_t af;
	union {
		struct {
		} addr;
		ip4_addr_t ipv4;
		struct rte_ipv6_addr ipv6;
	};
};

static inline bool l3_addr_eq(const struct l3_addr *a, const struct l3_addr *b) {
	if (a->af != b->af)
		return false;

	switch (a->af) {
	case GR_AF_IP4:
		return a->ipv4 == b->ipv4;
	case GR_AF_IP6:
		return memcmp(&a->ipv6, &b->ipv6, sizeof(a->ipv6)) == 0;
	default:
		break;
	}
	return true;
}

// Portable address formatting functions.
// Each returns buf for inline use in printf: printf("%s", eth_format(buf, &mac));

#define ETH_BUFSZ 18
#define IP4_BUFSZ INET_ADDRSTRLEN
#define IP6_BUFSZ INET6_ADDRSTRLEN
#define IP4_NET_BUFSZ (INET_ADDRSTRLEN + 3)
#define IP6_NET_BUFSZ (INET6_ADDRSTRLEN + 4)
#define ADDR_BUFSZ IP6_NET_BUFSZ

static inline const char *eth_format(char buf[static ETH_BUFSZ], const struct rte_ether_addr *mac) {
	if (mac == NULL)
		return "(nil)";
	snprintf(
		buf,
		ETH_BUFSZ,
		"%02hhx:%02hhx:%02hhx:%02hhx:%02hhx:%02hhx",
		mac->addr_bytes[0],
		mac->addr_bytes[1],
		mac->addr_bytes[2],
		mac->addr_bytes[3],
		mac->addr_bytes[4],
		mac->addr_bytes[5]
	);
	return buf;
}

static inline const char *ip4_format(char buf[static IP4_BUFSZ], const ip4_addr_t *ip) {
	if (ip == NULL)
		return "(nil)";
	inet_ntop(AF_INET, ip, buf, IP4_BUFSZ);
	return buf;
}

static inline const char *ip6_format(char buf[static IP6_BUFSZ], const struct rte_ipv6_addr *ip) {
	if (ip == NULL)
		return "(nil)";
	inet_ntop(AF_INET6, ip, buf, IP6_BUFSZ);
	return buf;
}

static inline const char *
ip4_net_format(char buf[static IP4_NET_BUFSZ], const struct ip4_net *net) {
	if (net == NULL)
		return "(nil)";
	char addr[INET_ADDRSTRLEN];
	inet_ntop(AF_INET, &net->ip, addr, sizeof(addr));
	snprintf(buf, IP4_NET_BUFSZ, "%s/%hhu", addr, net->prefixlen);
	return buf;
}

static inline const char *
ip6_net_format(char buf[static IP6_NET_BUFSZ], const struct ip6_net *net) {
	if (net == NULL)
		return "(nil)";
	char addr[INET6_ADDRSTRLEN];
	inet_ntop(AF_INET6, &net->ip, addr, sizeof(addr));
	snprintf(buf, IP6_NET_BUFSZ, "%s/%hhu", addr, net->prefixlen);
	return buf;
}

static inline const char *
addr_format(char buf[static ADDR_BUFSZ], int width, const void *addr) {
	if (addr == NULL)
		return "(nil)";
	switch (width) {
	case 2:
		return eth_format(buf, addr);
	case 4:
		return ip4_format(buf, addr);
	case 6:
		return ip6_format(buf, addr);
	case 32:
		return ip4_net_format(buf, addr);
	case 128:
		return ip6_net_format(buf, addr);
	}
	snprintf(buf, ADDR_BUFSZ, "0x%lx", (uintptr_t)addr);
	return buf;
}
