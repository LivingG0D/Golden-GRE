// golden-gre-relay: carry a tunnel's UDP packets between two servers inside a disguise that a filtered
// IPv4 path lets through. The tunnel (GRE-in-FOU on loopback) sends its packets to --local; each one is
// wrapped and sent to the peer's relay, which unwraps it and hands it to its own tunnel: to --reply if
// given (the tunnel's FOU address), else to the sender of the last local packet, which means nothing
// reaches the tunnel until the tunnel has sent something. Batches with recvmmsg/sendmmsg.
//
//   gcc -O2 -Wall -o golden-gre-relay golden-gre-relay.c
//   golden-gre-relay --facade dns|icmp --bind <public_ip> --peer <peer_ip> --local <ip:port>
//                    [--reply <ip:port>] [--port 53] [--itype 0]
//
// dns:  UDP from an ephemeral port to <peer>:53, framed as a DNS query (one question, EDNS0 OPT record
//       whose RDATA is the payload); listens on <bind>:53 (--port).
// icmp: ICMP messages of --itype (0 = unsolicited echo reply, so no kernel answers it); needs root.
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BATCH 64
#define BUF 2048
#define DNS_HDR 39  // 12 header + 16 question + 11 OPT record header
#define ICMP_HDR 8
#define HEAD 64     // room in front of the payload for the facade header
#define IDENT 0x7462

static const uint8_t QUESTION[16] = {5, 'p', 'r', 'o', 'b', 'e', 4, 't', 'e', 's', 't', 0, 0, 16, 0, 1};

static uint8_t bufs[BATCH][BUF];
static struct sockaddr_in names[BATCH];
static struct iovec iov[BATCH];
static struct mmsghdr msgs[BATCH];

static void die(const char *what) {
  perror(what);
  exit(1);
}

static struct sockaddr_in mkaddr(const char *ip, int port) {
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
  if (inet_pton(AF_INET, ip, &a.sin_addr) != 1) {
    fprintf(stderr, "bad address %s\n", ip);
    exit(1);
  }
  return a;
}

static int udp_socket(struct sockaddr_in a) {
  int s = socket(AF_INET, SOCK_DGRAM, 0);
  int big = 4 << 20;
  if (s < 0) die("socket");
  setsockopt(s, SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
  setsockopt(s, SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
  if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) die("bind");
  return s;
}

static uint16_t csum(const uint8_t *p, size_t n) {
  uint32_t t = 0;
  for (; n > 1; p += 2, n -= 2) t += (p[0] << 8) | p[1];
  if (n) t += p[0] << 8;
  while (t >> 16) t = (t & 0xFFFF) + (t >> 16);
  return (uint16_t)~t;
}

static void put16(uint8_t *p, unsigned v) {
  p[0] = v >> 8;
  p[1] = v & 0xFF;
}

static void dns_head(uint8_t *h, unsigned id, size_t payload) {
  static const uint8_t flags[10] = {0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01};
  put16(h, id);
  memcpy(h + 2, flags, sizeof flags);
  memcpy(h + 12, QUESTION, sizeof QUESTION);
  h[28] = 0;                // OPT owner name: root
  put16(h + 29, 41);        // type OPT
  put16(h + 31, 4096);      // UDP payload size
  memset(h + 33, 0, 4);     // extended rcode / flags
  put16(h + 37, payload);   // RDATA length
}

static void icmp_head(uint8_t *h, int type, unsigned seq, size_t payload) {
  h[0] = type;
  h[1] = 0;
  put16(h + 2, 0);
  put16(h + 4, IDENT);
  put16(h + 6, seq);
  put16(h + 2, csum(h, ICMP_HDR + payload));
}

int main(int argc, char **argv) {
  const char *facade = NULL, *bind_ip = NULL, *peer_ip = NULL, *local = NULL, *reply_arg = NULL;
  int port = 53, itype = 0;
  for (int i = 1; i + 1 < argc; i += 2) {
    if (!strcmp(argv[i], "--facade")) facade = argv[i + 1];
    else if (!strcmp(argv[i], "--bind")) bind_ip = argv[i + 1];
    else if (!strcmp(argv[i], "--peer")) peer_ip = argv[i + 1];
    else if (!strcmp(argv[i], "--local")) local = argv[i + 1];
    else if (!strcmp(argv[i], "--reply")) reply_arg = argv[i + 1];
    else if (!strcmp(argv[i], "--port")) port = atoi(argv[i + 1]);
    else if (!strcmp(argv[i], "--itype")) itype = atoi(argv[i + 1]);
  }
  if (!facade || !bind_ip || !peer_ip || !local || (strcmp(facade, "dns") && strcmp(facade, "icmp"))) {
    fprintf(stderr, "usage: %s --facade dns|icmp --bind IP --peer IP --local IP:PORT [--reply IP:PORT] [--port 53] [--itype 0]\n", argv[0]);
    return 1;
  }
  int is_dns = !strcmp(facade, "dns");
  char lip[64];
  snprintf(lip, sizeof lip, "%s", local);
  char *colon = strrchr(lip, ':');
  if (!colon) die("--local needs ip:port");
  *colon = 0;

  int loc = udp_socket(mkaddr(lip, atoi(colon + 1)));
  int rx, tx;
  struct sockaddr_in peer;
  if (is_dns) {
    rx = udp_socket(mkaddr(bind_ip, port));
    tx = udp_socket(mkaddr(bind_ip, 0));
    peer = mkaddr(peer_ip, port);
  } else {
    rx = tx = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (rx < 0) die("raw socket (root needed)");
    struct sockaddr_in b = mkaddr(bind_ip, 0);
    if (bind(rx, (struct sockaddr *)&b, sizeof b) < 0) die("bind");
    int big = 4 << 20;
    setsockopt(rx, SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
    setsockopt(rx, SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
    peer = mkaddr(peer_ip, 0);
  }

  struct sockaddr_in reply;
  int have_reply = 0;
  if (reply_arg) {
    char rip[64];
    snprintf(rip, sizeof rip, "%s", reply_arg);
    char *rcolon = strrchr(rip, ':');
    if (!rcolon) die("--reply needs ip:port");
    *rcolon = 0;
    reply = mkaddr(rip, atoi(rcolon + 1));
    have_reply = 1;
  }
  unsigned seq = 0;
  unsigned long ntx = 0, nrx = 0, nbad = 0;
  time_t next = time(NULL) + 60;
  struct pollfd pf[2] = {{loc, POLLIN, 0}, {rx, POLLIN, 0}};
  printf("golden-gre-relay up: %s %s <-> %s, local %s\n", facade, bind_ip, peer_ip, local);
  fflush(stdout);

  for (;;) {
    poll(pf, 2, 1000);
    if (pf[0].revents & POLLIN) {  // local tunnel endpoint -> wire
      for (int i = 0; i < BATCH; i++) {
        iov[i] = (struct iovec){bufs[i] + HEAD, BUF - HEAD};
        msgs[i].msg_hdr = (struct msghdr){.msg_name = &names[i], .msg_namelen = sizeof names[i], .msg_iov = &iov[i], .msg_iovlen = 1};
      }
      int n = recvmmsg(loc, msgs, BATCH, MSG_DONTWAIT, NULL);
      if (n > 0) {
        struct mmsghdr out[BATCH];
        struct iovec oiov[BATCH];
        for (int i = 0; i < n; i++) {
          size_t len = msgs[i].msg_len;
          reply = names[i];
          have_reply = 1;
          seq++;
          size_t hdr = is_dns ? DNS_HDR : ICMP_HDR;
          uint8_t *start = bufs[i] + HEAD - hdr;
          if (is_dns) dns_head(start, seq, len);
          else icmp_head(start, itype, seq, len);
          oiov[i] = (struct iovec){start, hdr + len};
          out[i].msg_hdr = (struct msghdr){.msg_name = &peer, .msg_namelen = sizeof peer, .msg_iov = &oiov[i], .msg_iovlen = 1};
        }
        int sent = sendmmsg(tx, out, n, 0);
        if (sent > 0) ntx += sent;
      }
    }
    if (pf[1].revents & POLLIN) {  // wire -> local tunnel endpoint
      for (int i = 0; i < BATCH; i++) {
        iov[i] = (struct iovec){bufs[i], BUF};
        msgs[i].msg_hdr = (struct msghdr){.msg_name = &names[i], .msg_namelen = sizeof names[i], .msg_iov = &iov[i], .msg_iovlen = 1};
      }
      int n = recvmmsg(rx, msgs, BATCH, MSG_DONTWAIT, NULL);
      if (n > 0 && have_reply) {
        struct mmsghdr out[BATCH];
        struct iovec oiov[BATCH];
        int m = 0;
        for (int i = 0; i < n; i++) {
          uint8_t *p = bufs[i];
          size_t len = msgs[i].msg_len;
          if (names[i].sin_addr.s_addr != peer.sin_addr.s_addr) continue;
          if (is_dns) {
            if (len <= DNS_HDR || memcmp(p + 12, QUESTION, sizeof QUESTION)) { nbad++; continue; }
            oiov[m] = (struct iovec){p + DNS_HDR, len - DNS_HDR};
          } else {
            size_t ihl = (p[0] & 15) * 4;
            if (len <= ihl + ICMP_HDR || p[ihl] != itype || ((p[ihl + 4] << 8) | p[ihl + 5]) != IDENT) { nbad++; continue; }
            oiov[m] = (struct iovec){p + ihl + ICMP_HDR, len - ihl - ICMP_HDR};
          }
          out[m].msg_hdr = (struct msghdr){.msg_name = &reply, .msg_namelen = sizeof reply, .msg_iov = &oiov[m], .msg_iovlen = 1};
          m++;
        }
        if (m) {
          int sent = sendmmsg(loc, out, m, 0);
          if (sent > 0) nrx += sent;
        }
      }
    }
    if (time(NULL) >= next) {
      printf("tx=%lu rx=%lu bad=%lu\n", ntx, nrx, nbad);
      fflush(stdout);
      next += 60;
    }
  }
}
