// SPDX-License-Identifier: BSD-3-Clause

// Reproducer for lost GR_EVENT_FDB_ADD notifications.
//
// A single process (like zebra with the grout dplane plugin) subscribes to
// GR_EVENT_FDB_ADD with suppress_self_events=true and, at the same time,
// issues GR_NH_ADD/GR_NH_DEL requests on another socket. Meanwhile, frames
// with unique source MACs are injected on a bridge member so that grout
// learns them in the datapath.
//
// Every learned MAC must be notified. Any MAC present in the FDB without a
// matching GR_EVENT_FDB_ADD is a lost notification.

// clang-format off
#include <gr_api_client_impl.h>
// clang-format on

#include <gr_l2.h>
#include <gr_nexthop.h>

#include <arpa/inet.h>
#include <getopt.h>
#include <linux/if_packet.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define MAC_PREFIX 0x02, 0x00, 0x5e, 0x10
#define CHURN_NH_ID 100
#define MAX_MACS 0xffff

static atomic_bool churn_stop;
static const char *sock_path;

static void *nexthop_churn(void *) {
	struct gr_api_client *c = gr_api_client_connect(sock_path);
	struct gr_nh_add_req add = {
		.exist_ok = true,
		.nh.type = GR_NH_T_BLACKHOLE,
		.nh.origin = GR_NH_ORIGIN_STATIC,
		.nh.vrf_id = GR_VRF_DEFAULT_ID,
		.nh.nh_id = CHURN_NH_ID,
	};
	struct gr_nh_del_req del = {.missing_ok = true, .nh.nh_id = CHURN_NH_ID};
	unsigned long n = 0;

	if (c == NULL) {
		perror("connect");
		exit(2);
	}
	// Each GR_NH_DEL ends up in nexthop_destroy() which drains the
	// control queue while the API request of this process is processed.
	while (!atomic_load(&churn_stop)) {
		if (gr_api_client_send_recv(c, GR_NH_ADD, sizeof(add), &add, NULL) < 0) {
			perror("GR_NH_ADD");
			exit(2);
		}
		if (gr_api_client_send_recv(c, GR_NH_DEL, sizeof(del), &del, NULL) < 0) {
			perror("GR_NH_DEL");
			exit(2);
		}
		n++;
	}
	printf("nexthop add/del cycles: %lu\n", n);
	gr_api_client_disconnect(c);
	return NULL;
}

static bool is_test_mac(const struct rte_ether_addr *mac) {
	static const uint8_t prefix[] = {MAC_PREFIX};
	return memcmp(mac->addr_bytes, prefix, sizeof(prefix)) == 0;
}

static unsigned mac_index(const struct rte_ether_addr *mac) {
	return (mac->addr_bytes[4] << 8) | mac->addr_bytes[5];
}

static void inject_frames(const char *ifname, unsigned count) {
	struct sockaddr_ll addr = {
		.sll_family = AF_PACKET,
		.sll_ifindex = if_nametoindex(ifname),
		.sll_halen = ETH_ALEN,
	};
	struct timespec gap = {.tv_nsec = 2 * 1000 * 1000};
	uint8_t frame[64] = {
		0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // dst: broadcast
		MAC_PREFIX, 0, 0, // src: filled below
		0x88, 0xb5, // local experimental ethertype
	};
	int fd;

	if (addr.sll_ifindex == 0) {
		perror(ifname);
		exit(2);
	}
	if ((fd = socket(AF_PACKET, SOCK_RAW, 0)) < 0) {
		perror("socket(AF_PACKET)");
		exit(2);
	}
	for (unsigned i = 0; i < count; i++) {
		frame[10] = i >> 8;
		frame[11] = i & 0xff;
		if (sendto(fd, frame, sizeof(frame), 0, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
			perror("sendto");
			exit(2);
		}
		nanosleep(&gap, NULL);
	}
	close(fd);
}

static void usage(const char *prog) {
	fprintf(stderr, "usage: %s -i IFNAME [-n COUNT] [-x]\n", prog);
	fprintf(stderr, "  -i IFNAME  kernel side of a grout bridge member port\n");
	fprintf(stderr, "  -n COUNT   number of unique source MACs to inject (default 100)\n");
	fprintf(stderr, "  -x         do not run the GR_NH_ADD/GR_NH_DEL churn (control run)\n");
	exit(2);
}

int main(int argc, char **argv) {
	struct gr_event_subscribe_req sub = {
		.suppress_self_events = true,
		.ev_type = GR_EVENT_FDB_ADD,
	};
	struct gr_fdb_list_req list = {.bridge_id = GR_IFACE_ID_UNDEF, .iface_id = GR_IFACE_ID_UNDEF};
	struct timeval rcv_timeout = {.tv_sec = 2};
	unsigned count = 100, learned = 0, notified = 0, missing = 0;
	static bool seen_event[MAX_MACS + 1], seen_fdb[MAX_MACS + 1];
	const struct gr_fdb_entry *fdb;
	struct gr_api_client *events;
	struct gr_api_event *e;
	const char *ifname = NULL;
	bool churn = true;
	pthread_t thread;
	int opt, ret;

	while ((opt = getopt(argc, argv, "i:n:x")) != -1) {
		switch (opt) {
		case 'i':
			ifname = optarg;
			break;
		case 'n':
			count = strtoul(optarg, NULL, 10);
			break;
		case 'x':
			churn = false;
			break;
		default:
			usage(argv[0]);
		}
	}
	if (ifname == NULL || count == 0 || count > MAX_MACS)
		usage(argv[0]);

	if ((sock_path = getenv("GROUT_SOCK_PATH")) == NULL)
		sock_path = GR_DEFAULT_SOCK_PATH;

	if ((events = gr_api_client_connect(sock_path)) == NULL) {
		perror("connect");
		return 2;
	}
	if (gr_api_client_send_recv(events, GR_EVENT_SUBSCRIBE, sizeof(sub), &sub, NULL) < 0) {
		perror("GR_EVENT_SUBSCRIBE");
		return 2;
	}

	atomic_init(&churn_stop, false);
	if (churn)
		pthread_create(&thread, NULL, nexthop_churn, NULL);

	inject_frames(ifname, count);

	atomic_store(&churn_stop, true);
	if (churn)
		pthread_join(thread, NULL);

	// Collect notifications until none arrived for rcv_timeout.
	setsockopt(events->sock_fd, SOL_SOCKET, SO_RCVTIMEO, &rcv_timeout, sizeof(rcv_timeout));
	while (gr_api_client_event_recv(events, &e) >= 0) {
		const struct gr_fdb_entry *ev_fdb = PAYLOAD(e);
		if (e->ev_type == GR_EVENT_FDB_ADD && is_test_mac(&ev_fdb->mac))
			seen_event[mac_index(&ev_fdb->mac)] = true;
		free(e);
	}

	struct gr_api_client *c = gr_api_client_connect(sock_path);
	if (c == NULL) {
		perror("connect");
		return 2;
	}
	gr_api_client_stream_foreach (fdb, ret, c, GR_FDB_LIST, sizeof(list), &list) {
		if (is_test_mac(&fdb->mac) && (fdb->flags & GR_FDB_F_LEARN))
			seen_fdb[mac_index(&fdb->mac)] = true;
	}
	if (ret < 0) {
		perror("GR_FDB_LIST");
		return 2;
	}

	for (unsigned i = 0; i < count; i++) {
		learned += seen_fdb[i];
		notified += seen_event[i];
		if (seen_fdb[i] && !seen_event[i]) {
			printf("learned without GR_EVENT_FDB_ADD: 02:00:5e:10:%02x:%02x\n",
			       i >> 8,
			       i & 0xff);
			missing++;
		}
	}
	printf("injected=%u learned=%u notified=%u missing=%u\n", count, learned, notified, missing);

	gr_api_client_disconnect(c);
	gr_api_client_disconnect(events);

	return missing > 0 ? 1 : 0;
}
