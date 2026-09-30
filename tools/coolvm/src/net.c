/*
 * VM-only virtio-net (virtio-mmio v2) with a user-mode NAT, in the style of
 * QEMU's slirp but much smaller: no root, no vmnet, no tap. Guest Ethernet
 * frames are terminated here and turned into ordinary host socket calls.
 *
 *   10.0.2.15  the guest (handed out by DHCP)
 *   10.0.2.2   gateway: answers ARP, DHCP, ICMP echo; TCP/UDP to it go to the host's 127.0.0.1
 *   10.0.2.3   DNS: A queries are answered with the host's getaddrinfo()
 *
 * TCP: every guest connection is terminated by a small TCP state machine that
 * talks to the guest and relays bytes to a non-blocking host socket (go-back-N
 * retransmission towards the guest, in-order-only acceptance from the guest).
 * UDP: one host socket per guest source port. ICMP echo to the outside uses
 * macOS's unprivileged SOCK_DGRAM/IPPROTO_ICMP sockets.
 * Inbound forwarding (--net-forward [addr:]host:guest): coolvm listens on the
 * host port; each accepted connection opens a TCP connection to the guest port
 * from 10.0.2.2 (an ephemeral port), then relays like an outbound one.
 *
 * All state is protected by g.lock: the vCPU threads call net_mmio with it
 * held, the poll thread and the DNS threads take it.
 * COOLVM_NET_DEBUG=1 in the environment logs frames and bad guest checksums.
 */
#include "virtio.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define IP4(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))
#define NET_GW IP4(10, 0, 2, 2)
#define NET_DNS IP4(10, 0, 2, 3)
#define NET_GUEST IP4(10, 0, 2, 15)
#define NET_MASK IP4(255, 255, 255, 0)
#define VNET_HDR 12 /* virtio_net_hdr with VERSION_1 (num_buffers included) */
#define FRAME_MAX 1514
#define MSS 1460

static const uint8_t gw_mac[6] = {0x52, 0x55, 0x0a, 0x00, 0x02, 0x02};
static uint8_t guest_mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
static bool dbg;

/* ---- byte helpers ------------------------------------------------------- */
static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static void wbe16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = (uint8_t)v; }
static void wbe32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t le64(const uint8_t *p) { return le32(p) | (uint64_t)le32(p + 4) << 32; }
static void wle16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = v >> 8; }
static void wle32(uint8_t *p, uint32_t v) { wle16(p, (uint16_t)v); wle16(p + 2, v >> 16); }

static uint32_t csum_add(uint32_t s, const uint8_t *p, size_t n)
{
    for (; n > 1; n -= 2, p += 2) s += be16(p);
    if (n) s += p[0] << 8;
    return s;
}
static uint16_t csum_fold(uint32_t s)
{
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (uint16_t)~s;
}
static uint32_t pseudo(uint32_t src, uint32_t dst, int proto, size_t len)
{
    return (src >> 16) + (src & 0xffff) + (dst >> 16) + (dst & 0xffff) + proto + (uint32_t)len;
}
static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static bool seq_lt(uint32_t a, uint32_t b) { return (int32_t)(a - b) < 0; }
static bool seq_le(uint32_t a, uint32_t b) { return (int32_t)(a - b) <= 0; }

/* ---- virtio-mmio device ------------------------------------------------- */
#define VIRTIO_NET 1
#define F_MAC (1u << 5)
#define F_STATUS (1u << 16)
#define F_VERSION_1 1u /* feature word 1 */

static struct { uint32_t status, devsel, drvsel, drvfeat[2], qsel, isr; struct vq q[2]; } nv;

/* Frames waiting for guest receive buffers. */
#define RXQ 512
static uint8_t rxq[RXQ][FRAME_MAX];
static uint16_t rxq_len[RXQ];
static unsigned rxq_head, rxq_tail;
static uint64_t stat_tx, stat_rx, stat_rxdrop;

static int wake_pipe[2] = {-1, -1};

static uint8_t *gptr(uint64_t pa, uint64_t len)
{
    return virtio_guest(pa, len);
}

static bool vq_desc(struct vq *q, unsigned id, uint64_t *addr, uint32_t *len, uint16_t *flags, uint16_t *next)
{
    return virtio_desc(q,id,addr,len,flags,next);
}

static bool vq_ok(struct vq *q) { return (nv.status & 4) && q->ready && q->num; }

static void vq_used(struct vq *q, uint16_t head, uint32_t len)
{
    virtio_used(q,head,len);
}

static void vq_irq(struct vq *q)
{
    uint8_t *avail = gptr(q->avail, 4);
    if (avail && !(le16(avail) & 1)) nv.isr |= 1;
    aic_update_locked();
}

/* Deliver queued frames into the guest's receive queue (0). */
static void rx_flush(void)
{
    struct vq *q = &nv.q[0];
    bool any = false;
    if (!vq_ok(q)) return;
    uint8_t *avail = gptr(q->avail, 4 + 2 * q->num);
    if (!avail) return;
    while (rxq_head != rxq_tail) {
        atomic_thread_fence(memory_order_acquire);
        if (le16(avail + 2) == q->last_avail) break;
        uint16_t head = le16(avail + 4 + 2 * (q->last_avail % q->num));
        q->last_avail++;
        uint8_t hdr[VNET_HDR] = {0};
        hdr[10] = 1; /* num_buffers */
        const uint8_t *src[2] = {hdr, rxq[rxq_head]};
        size_t srclen[2] = {VNET_HDR, rxq_len[rxq_head]}, si = 0, so = 0, total = 0;
        unsigned id = head, steps = 0;
        uint64_t addr; uint32_t len; uint16_t flags, next;
        while (si < 2 && ++steps <= q->num && vq_desc(q, id, &addr, &len, &flags, &next) && (flags & 2)) {
            uint8_t *d = gptr(addr, len);
            if (!d) break;
            uint32_t off = 0;
            while (off < len && si < 2) {
                size_t n = srclen[si] - so;
                if (n > len - off) n = len - off;
                memcpy(d + off, src[si] + so, n);
                off += n; so += n; total += n;
                if (so == srclen[si]) { si++; so = 0; }
            }
            if (!(flags & 1)) break;
            id = next;
        }
        if (si < 2) stat_rxdrop++; /* buffer too small: the frame is lost */
        else stat_rx++;
        vq_used(q, head, (uint32_t)total);
        rxq_head = (rxq_head + 1) % RXQ;
        any = true;
    }
    if (any) vq_irq(q);
}

static void to_guest(const uint8_t *frame, size_t len)
{
    unsigned next = (rxq_tail + 1) % RXQ;
    if (len > FRAME_MAX || next == rxq_head) { stat_rxdrop++; return; }
    memcpy(rxq[rxq_tail], frame, len);
    rxq_len[rxq_tail] = (uint16_t)len;
    rxq_tail = next;
    rx_flush();
}

static void eth_input(uint8_t *f, size_t len);

static void tx_process(void)
{
    struct vq *q = &nv.q[1];
    static uint8_t buf[VNET_HDR + 65536];
    if (!vq_ok(q)) return;
    uint8_t *avail = gptr(q->avail, 4 + 2 * q->num);
    if (!avail) return;
    bool any = false;
    for (;;) {
        atomic_thread_fence(memory_order_acquire);
        if (le16(avail + 2) == q->last_avail) break;
        uint16_t head = le16(avail + 4 + 2 * (q->last_avail % q->num));
        q->last_avail++;
        size_t total = 0;
        unsigned id = head, steps = 0;
        uint64_t addr; uint32_t len; uint16_t flags, next;
        while (++steps <= q->num && vq_desc(q, id, &addr, &len, &flags, &next)) {
            uint8_t *s = gptr(addr, len);
            if (!s || total + len > sizeof buf) { total = 0; break; }
            memcpy(buf + total, s, len);
            total += len;
            if (!(flags & 1)) break;
            id = next;
        }
        vq_used(q, head, 0);
        any = true;
        if (total > VNET_HDR) { stat_tx++; eth_input(buf + VNET_HDR, total - VNET_HDR); }
    }
    if (any) vq_irq(q);
}

bool net_irq_level(void) { return g.net && nv.isr != 0; }

bool net_mmio(uint64_t off, int size, bool wr, uint64_t *val)
{
    if (off >= 0x100 && off < 0x108 && !wr) { /* config: mac[6], status u16 */
        uint8_t cfg[8] = {0};
        memcpy(cfg, guest_mac, 6);
        cfg[6] = 1; /* VIRTIO_NET_S_LINK_UP */
        uint64_t v = 0;
        for (int i = 0; i < size && off + i < 0x108; i++) v |= (uint64_t)cfg[off - 0x100 + i] << (8 * i);
        *val = v;
        return true;
    }
    if (size != 4) return false;
    struct vq *q = nv.qsel < 2 ? &nv.q[nv.qsel] : NULL;
    uint32_t v = (uint32_t)*val, r = 0;
    if (wr) {
        switch (off) {
        case 0x14: nv.devsel = v; break;
        case 0x24: nv.drvsel = v; break;
        case 0x20: if (nv.drvsel < 2) nv.drvfeat[nv.drvsel] = v; break;
        case 0x30: nv.qsel = v; break;
        case 0x38: if (!q || !v || v > 256 || (v & (v - 1))) return false; q->num = v; break;
        case 0x44: if (!q) return false; q->ready = v & 1; break;
        case 0x50: if (v == 1) tx_process(); rx_flush(); break;
        case 0x64: nv.isr &= ~v; aic_update_locked(); break;
        case 0x70:
            if (v == 0) { memset(&nv, 0, sizeof nv); rxq_head = rxq_tail; aic_update_locked(); }
            else {
                nv.status = v;
                if ((v & 8) && !(nv.drvfeat[1] & F_VERSION_1)) nv.status &= ~8u;
                if (v & 4) rx_flush();
            }
            break;
        case 0x80: if (q) q->desc = (q->desc & ~0xffffffffULL) | v; break;
        case 0x84: if (q) q->desc = (q->desc & 0xffffffffULL) | (uint64_t)v << 32; break;
        case 0x90: if (q) q->avail = (q->avail & ~0xffffffffULL) | v; break;
        case 0x94: if (q) q->avail = (q->avail & 0xffffffffULL) | (uint64_t)v << 32; break;
        case 0xa0: if (q) q->used = (q->used & ~0xffffffffULL) | v; break;
        case 0xa4: if (q) q->used = (q->used & 0xffffffffULL) | (uint64_t)v << 32; break;
        default: return false;
        }
        return true;
    }
    switch (off) {
    case 0x00: r = 0x74726976; break;
    case 0x04: r = 2; break;
    case 0x08: r = VIRTIO_NET; break;
    case 0x0c: r = 0x554d5643; break;
    case 0x10: r = nv.devsel == 0 ? F_MAC | F_STATUS : (nv.devsel == 1 ? F_VERSION_1 : 0); break;
    case 0x20: r = nv.drvsel < 2 ? nv.drvfeat[nv.drvsel] : 0; break;
    case 0x34: r = q ? 256 : 0; break;
    case 0x38: r = q ? q->num : 0; break;
    case 0x44: r = q ? q->ready : 0; break;
    case 0x60: r = nv.isr; break;
    case 0x70: r = nv.status; break;
    case 0xfc: r = 0; break;
    default: return false;
    }
    *val = r;
    return true;
}

/* ---- output helpers ----------------------------------------------------- */
static void ip_output(int proto, uint32_t src, uint32_t dst, const uint8_t *payload, size_t len)
{
    uint8_t f[FRAME_MAX];
    static uint16_t ip_id;
    if (len > FRAME_MAX - 34) return;
    memcpy(f, dst == 0xffffffff ? (const uint8_t *)"\xff\xff\xff\xff\xff\xff" : guest_mac, 6);
    memcpy(f + 6, gw_mac, 6);
    wbe16(f + 12, 0x0800);
    uint8_t *ip = f + 14;
    ip[0] = 0x45; ip[1] = 0;
    wbe16(ip + 2, (uint16_t)(20 + len));
    wbe16(ip + 4, ip_id++);
    wbe16(ip + 6, 0x4000); /* DF */
    ip[8] = 64; ip[9] = (uint8_t)proto;
    wbe16(ip + 10, 0);
    wbe32(ip + 12, src); wbe32(ip + 16, dst);
    wbe16(ip + 10, csum_fold(csum_add(0, ip, 20)));
    memcpy(ip + 20, payload, len);
    to_guest(f, 34 + len);
}

static void udp_output(uint32_t src, int sport, uint32_t dst, int dport, const uint8_t *data, size_t len)
{
    uint8_t u[FRAME_MAX];
    if (len > FRAME_MAX - 42) return;
    wbe16(u, (uint16_t)sport); wbe16(u + 2, (uint16_t)dport);
    wbe16(u + 4, (uint16_t)(8 + len)); wbe16(u + 6, 0);
    memcpy(u + 8, data, len);
    uint16_t c = csum_fold(csum_add(pseudo(src, dst, 17, 8 + len), u, 8 + len));
    wbe16(u + 6, c ? c : 0xffff);
    ip_output(17, src, dst, u, 8 + len);
}

/* A guest destination on the host: the gateway means the host itself. */
static struct sockaddr_in host_addr(uint32_t ip, int port)
{
    struct sockaddr_in a = {0};
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(ip == NET_GW || ip == NET_DNS ? IP4(127, 0, 0, 1) : ip);
    return a;
}
static uint32_t from_host(uint32_t ip) { return ip == IP4(127, 0, 0, 1) ? NET_GW : ip; }

static void wake(void)
{
    if (wake_pipe[1] >= 0) { char c = 0; (void)!write(wake_pipe[1], &c, 1); }
}

static int nb_socket(int type, int proto)
{
    int fd = socket(AF_INET, type, proto);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    return fd;
}

/* ---- ARP, ICMP, DHCP ---------------------------------------------------- */
static void arp_input(uint8_t *f, size_t len)
{
    if (len < 42) return;
    uint8_t *a = f + 14;
    if (be16(a) != 1 || be16(a + 2) != 0x0800 || be16(a + 6) != 1) return;
    uint32_t tpa = be32(a + 24);
    memcpy(guest_mac, a + 8, 6);
    if (tpa != NET_GW && tpa != NET_DNS) return;
    uint8_t r[42];
    memcpy(r, a + 8, 6); memcpy(r + 6, gw_mac, 6); wbe16(r + 12, 0x0806);
    uint8_t *p = r + 14;
    wbe16(p, 1); wbe16(p + 2, 0x0800); p[4] = 6; p[5] = 4; wbe16(p + 6, 2);
    memcpy(p + 8, gw_mac, 6); wbe32(p + 14, tpa);
    memcpy(p + 18, a + 8, 6); memcpy(p + 24, a + 14, 4);
    to_guest(r, 42);
}

#define NPING 16
static struct ping { int fd; uint16_t id, seq; uint32_t dst; uint64_t t; } pings[NPING];

static void icmp_input(uint32_t src, uint32_t dst, uint8_t *p, size_t len)
{
    if (len < 8 || p[0] != 8) return;
    if (dst == NET_GW || dst == NET_DNS) {
        uint8_t r[FRAME_MAX];
        memcpy(r, p, len);
        r[0] = 0; wbe16(r + 2, 0);
        wbe16(r + 2, csum_fold(csum_add(0, r, len)));
        ip_output(1, dst, src, r, len);
        return;
    }
    struct ping *pg = NULL;
    for (int i = 0; i < NPING; i++) if (pings[i].fd <= 0) { pg = &pings[i]; break; }
    if (!pg) return;
    int fd = nb_socket(SOCK_DGRAM, IPPROTO_ICMP);
    if (fd < 0) { if (dbg) LOGE("net: no ICMP socket: %s\n", strerror(errno)); return; }
    struct sockaddr_in a = host_addr(dst, 0);
    uint8_t m[FRAME_MAX];
    memcpy(m, p, len);
    wbe16(m + 2, 0);
    wbe16(m + 2, csum_fold(csum_add(0, m, len)));
    if (sendto(fd, m, len, 0, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return; }
    pg->fd = fd; pg->id = be16(p + 4); pg->seq = be16(p + 6); pg->dst = dst; pg->t = now_ms();
    wake();
}

static void ping_readable(struct ping *pg)
{
    uint8_t b[2048];
    ssize_t n = recv(pg->fd, b, sizeof b, 0);
    if (n <= 0) return;
    uint8_t *p = b;
    if ((b[0] >> 4) == 4 && n >= 20 + 8 && (size_t)n >= (size_t)(b[0] & 15) * 4 + 8) { p += (b[0] & 15) * 4; n -= (b[0] & 15) * 4; }
    if (p[0] != 0) return;
    wbe16(p + 4, pg->id); wbe16(p + 6, pg->seq);
    wbe16(p + 2, 0);
    wbe16(p + 2, csum_fold(csum_add(0, p, (size_t)n)));
    ip_output(1, pg->dst, NET_GUEST, p, (size_t)n);
    close(pg->fd);
    pg->fd = 0;
}

static void dhcp_input(uint8_t *d, size_t len)
{
    if (len < 240 || d[0] != 1 || be32(d + 236) != 0x63825363) return;
    int type = 0;
    for (size_t i = 240; i + 1 < len && d[i] != 255;) {
        if (d[i] == 0) { i++; continue; }
        if (d[i] == 53 && d[i + 1] >= 1 && i + 2 < len) type = d[i + 2];
        i += 2 + d[i + 1];
    }
    if (type != 1 && type != 3) return;
    uint8_t r[300] = {0};
    r[0] = 2; r[1] = 1; r[2] = 6;
    memcpy(r + 4, d + 4, 4);   /* xid */
    memcpy(r + 10, d + 10, 2); /* flags */
    wbe32(r + 16, NET_GUEST);
    wbe32(r + 20, NET_GW);
    memcpy(r + 28, d + 28, 16); /* chaddr */
    wbe32(r + 236, 0x63825363);
    uint8_t *o = r + 240;
    *o++ = 53; *o++ = 1; *o++ = type == 1 ? 2 : 5;
    *o++ = 54; *o++ = 4; wbe32(o, NET_GW); o += 4;
    *o++ = 51; *o++ = 4; wbe32(o, 86400); o += 4;
    *o++ = 1; *o++ = 4; wbe32(o, NET_MASK); o += 4;
    *o++ = 3; *o++ = 4; wbe32(o, NET_GW); o += 4;
    *o++ = 6; *o++ = 4; wbe32(o, NET_DNS); o += 4;
    *o++ = 255;
    udp_output(NET_GW, 67, 0xffffffff, 68, r, sizeof r);
}

/* ---- DNS: answer A queries with getaddrinfo on a helper thread ---------- */
struct dnsq { uint8_t q[512]; size_t qlen, qend; int sport; char name[256]; int qtype; };

static void *dns_main(void *arg)
{
    struct dnsq *q = arg;
    uint8_t r[512];
    size_t n = q->qend;
    int rcode = 0, an = 0;
    struct addrinfo hints = {0}, *res = NULL;
    memcpy(r, q->q, n);
    if (getenv("COOLVM_NET_OFFLINE")) rcode = 2; /* pretend the host is offline (tests the guest's skip path) */
    else if (q->qtype == 1) {
        hints.ai_family = AF_INET;
        hints.ai_socktype = SOCK_STREAM;
        int e = getaddrinfo(q->name, NULL, &hints, &res);
        if (e == EAI_NONAME) rcode = 3;
        else if (e) rcode = 2;
        for (struct addrinfo *ai = res; ai && an < 8 && n + 16 <= sizeof r; ai = ai->ai_next) {
            uint32_t ip = ntohl(((struct sockaddr_in *)ai->ai_addr)->sin_addr.s_addr);
            wbe16(r + n, 0xc00c); wbe16(r + n + 2, 1); wbe16(r + n + 4, 1);
            wbe32(r + n + 6, 60); wbe16(r + n + 10, 4); wbe32(r + n + 12, ip);
            n += 16; an++;
        }
        if (res) freeaddrinfo(res);
    }
    wbe16(r + 2, (uint16_t)(0x8080 | (q->q[2] & 1) << 8 | rcode)); /* QR RD RA */
    wbe16(r + 4, 1); wbe16(r + 6, (uint16_t)an); wbe16(r + 8, 0); wbe16(r + 10, 0);
    if (dbg) LOGE("net: dns %s type %d -> %d answers rcode %d\n", q->name, q->qtype, an, rcode);
    pthread_mutex_lock(&g.lock);
    udp_output(NET_DNS, 53, NET_GUEST, q->sport, r, n);
    pthread_mutex_unlock(&g.lock);
    free(q);
    return NULL;
}

static void dns_input(int sport, uint8_t *d, size_t len)
{
    if (len < 17 || len > 512 || (d[2] & 0x80) || be16(d + 4) != 1) return;
    struct dnsq *q = calloc(1, sizeof *q);
    size_t i = 12, o = 0;
    while (i < len && d[i]) {
        size_t l = d[i];
        if (l > 63 || i + 1 + l >= len || o + l + 1 >= sizeof q->name) { free(q); return; }
        if (o) q->name[o++] = '.';
        memcpy(q->name + o, d + i + 1, l);
        o += l; i += 1 + l;
    }
    if (i + 5 > len) { free(q); return; }
    q->qtype = be16(d + i + 1);
    q->qend = i + 5; /* header + one question; extra (EDNS) records are dropped */
    memcpy(q->q, d, q->qend);
    q->qlen = len;
    q->sport = sport;
    pthread_t th;
    if (pthread_create(&th, NULL, dns_main, q)) { free(q); return; }
    pthread_detach(th);
}

/* ---- UDP ---------------------------------------------------------------- */
#define NUDP 32
static struct udpc { int fd; int gport; uint64_t t; } udps[NUDP];

static void udp_input(uint32_t src, uint32_t dst, uint8_t *u, size_t len)
{
    if (len < 8 || be16(u + 4) < 8 || be16(u + 4) > len) return;
    len = be16(u + 4);
    int sport = be16(u), dport = be16(u + 2);
    if (dport == 67) { dhcp_input(u + 8, len - 8); return; }
    if (dst == NET_DNS && dport == 53) { dns_input(sport, u + 8, len - 8); return; }
    if (dst == 0xffffffff || (dst & 0xf0000000) == 0xe0000000) return;
    struct udpc *c = NULL, *fr = NULL;
    for (int i = 0; i < NUDP; i++) {
        if (udps[i].fd > 0 && udps[i].gport == sport) c = &udps[i];
        else if (udps[i].fd <= 0 && !fr) fr = &udps[i];
    }
    if (!c) {
        if (!fr) return;
        int fd = nb_socket(SOCK_DGRAM, 0);
        if (fd < 0) return;
        c = fr; c->fd = fd; c->gport = sport;
        wake();
    }
    c->t = now_ms();
    struct sockaddr_in a = host_addr(dst, dport);
    sendto(c->fd, u + 8, len - 8, 0, (struct sockaddr *)&a, sizeof a);
    (void)src;
}

static void udp_readable(struct udpc *c)
{
    uint8_t b[FRAME_MAX];
    struct sockaddr_in a;
    socklen_t al = sizeof a;
    ssize_t n = recvfrom(c->fd, b, FRAME_MAX - 42, 0, (struct sockaddr *)&a, &al);
    if (n < 0) return;
    c->t = now_ms();
    udp_output(from_host(ntohl(a.sin_addr.s_addr)), ntohs(a.sin_port), NET_GUEST, c->gport, b, (size_t)n);
}

/* ---- TCP ---------------------------------------------------------------- */
#define NTCP 64
#define SBUF (256 * 1024)
#define RTO_MS 300
enum { T_FREE, T_CONNECTING, T_SYN_RCVD, T_EST, T_SYN_SENT /* forwarded: our SYN to the guest */ };
#define TH_FIN 1
#define TH_SYN 2
#define TH_RST 4
#define TH_PSH 8
#define TH_ACK 16

static struct tcb {
    int state, fd;
    uint32_t rip; int rport, gport; /* remote (as the guest sees it) and guest port */
    uint32_t iss, snd_una, snd_nxt, rcv_nxt, snd_wnd;
    uint8_t *sbuf; size_t slen;      /* bytes from the host starting at snd_una */
    bool host_eof, fin_sent, fin_acked, guest_fin;
    uint64_t rtx_t, idle_t, syn_t;
} tcbs[NTCP];
static uint64_t stat_tcp_conns;

static void tcp_send(struct tcb *t, int flags, uint32_t seq, const uint8_t *data, size_t len)
{
    uint8_t s[FRAME_MAX];
    size_t hl = flags & TH_SYN ? 24 : 20;
    wbe16(s, (uint16_t)t->rport); wbe16(s + 2, (uint16_t)t->gport);
    wbe32(s + 4, seq); wbe32(s + 8, flags & TH_ACK ? t->rcv_nxt : 0);
    s[12] = (uint8_t)(hl / 4) << 4; s[13] = (uint8_t)flags;
    wbe16(s + 14, 65535); wbe16(s + 16, 0); wbe16(s + 18, 0);
    if (flags & TH_SYN) { s[20] = 2; s[21] = 4; wbe16(s + 22, MSS); }
    memcpy(s + hl, data, len);
    wbe16(s + 16, csum_fold(csum_add(pseudo(t->rip, NET_GUEST, 6, hl + len), s, hl + len)));
    ip_output(6, t->rip, NET_GUEST, s, hl + len);
    t->idle_t = now_ms();
}

static void tcp_rst_reply(uint32_t src, uint32_t dst, int sport, int dport, uint32_t seq, uint32_t ack, bool has_ack)
{
    struct tcb t = {0};
    t.rip = dst; t.rport = dport; t.gport = sport; t.rcv_nxt = seq;
    tcp_send(&t, has_ack ? TH_RST : TH_RST | TH_ACK, has_ack ? ack : 0, NULL, 0);
    (void)src;
}

static void tcb_free(struct tcb *t)
{
    if (t->fd > 0) close(t->fd);
    free(t->sbuf);
    memset(t, 0, sizeof *t);
}

static void tcp_push(struct tcb *t)
{
    if (t->state != T_EST) return;
    for (;;) {
        size_t off = t->snd_nxt - t->snd_una - (t->fin_sent ? 1 : 0);
        if (t->fin_sent || off >= t->slen) break;
        int64_t wnd = (int64_t)t->snd_wnd - (int64_t)(t->snd_nxt - t->snd_una);
        if (wnd <= 0) break;
        size_t n = t->slen - off;
        if (n > MSS) n = MSS;
        if ((int64_t)n > wnd) n = (size_t)wnd;
        if (t->snd_nxt == t->snd_una) t->rtx_t = now_ms();
        tcp_send(t, TH_ACK | TH_PSH, t->snd_nxt, t->sbuf + off, n);
        t->snd_nxt += (uint32_t)n;
    }
    if (t->host_eof && !t->fin_sent && t->snd_nxt - t->snd_una == t->slen) {
        if (t->snd_nxt == t->snd_una) t->rtx_t = now_ms();
        tcp_send(t, TH_ACK | TH_FIN, t->snd_nxt, NULL, 0);
        t->snd_nxt++;
        t->fin_sent = true;
    }
}

static void tcp_input(uint32_t src, uint32_t dst, uint8_t *s, size_t len)
{
    if (len < 20 || (s[12] >> 4) * 4u < 20 || (s[12] >> 4) * 4u > len) return;
    int sport = be16(s), dport = be16(s + 2), flags = s[13];
    uint32_t seq = be32(s + 4), ack = be32(s + 8);
    size_t hl = (s[12] >> 4) * 4u, dl = len - hl;
    uint8_t *data = s + hl;
    struct tcb *t = NULL, *fr = NULL;
    for (int i = 0; i < NTCP; i++) {
        if (tcbs[i].state && tcbs[i].gport == sport && tcbs[i].rip == dst && tcbs[i].rport == dport) { t = &tcbs[i]; break; }
        if (!tcbs[i].state && !fr) fr = &tcbs[i];
    }
    if (!t) {
        if (flags & TH_RST) return;
        if ((flags & (TH_SYN | TH_ACK)) != TH_SYN || !fr || dst == NET_DNS) {
            tcp_rst_reply(src, dst, sport, dport, seq + (uint32_t)dl + ((flags & TH_SYN) ? 1 : 0) + ((flags & TH_FIN) ? 1 : 0), ack, flags & TH_ACK);
            return;
        }
        int fd = nb_socket(SOCK_STREAM, 0);
        if (fd < 0) { tcp_rst_reply(src, dst, sport, dport, seq + 1, 0, false); return; }
        struct sockaddr_in a = host_addr(dst, dport);
        if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0 && errno != EINPROGRESS) {
            close(fd);
            tcp_rst_reply(src, dst, sport, dport, seq + 1, 0, false);
            return;
        }
        t = fr;
        memset(t, 0, sizeof *t);
        t->state = T_CONNECTING; t->fd = fd;
        t->rip = dst; t->rport = dport; t->gport = sport;
        t->rcv_nxt = seq + 1;
        t->iss = arc4random();
        t->snd_una = t->snd_nxt = t->iss;
        t->snd_wnd = be16(s + 14);
        t->sbuf = malloc(SBUF);
        t->idle_t = now_ms();
        stat_tcp_conns++;
        if (dbg) LOGE("net: tcp connect %u.%u.%u.%u:%d from guest port %d\n", dst >> 24, dst >> 16 & 255, dst >> 8 & 255, dst & 255, dport, sport);
        wake();
        return;
    }
    t->idle_t = now_ms();
    if (flags & TH_RST) { tcb_free(t); return; }
    if (t->state == T_SYN_SENT) {
        if ((flags & (TH_SYN | TH_ACK)) != (TH_SYN | TH_ACK) || ack != t->iss + 1) return;
        t->rcv_nxt = seq + 1;
        t->snd_una = t->snd_nxt = t->iss + 1;
        t->snd_wnd = be16(s + 14);
        t->state = T_EST;
        t->rtx_t = now_ms();
        tcp_send(t, TH_ACK, t->snd_nxt, NULL, 0);
        tcp_push(t);
        wake();
        return;
    }
    if (flags & TH_SYN) {
        if (t->state == T_SYN_RCVD) tcp_send(t, TH_SYN | TH_ACK, t->iss, NULL, 0);
        return;
    }
    if (t->state == T_CONNECTING) return;
    if (flags & TH_ACK) {
        if (seq_lt(t->snd_una, ack) && seq_le(ack, t->snd_nxt)) {
            uint32_t acked = ack - t->snd_una;
            if (t->state == T_SYN_RCVD) { acked--; t->state = T_EST; }
            if (t->fin_sent && ack == t->snd_nxt) { acked--; t->fin_acked = true; }
            if (acked > t->slen) acked = (uint32_t)t->slen;
            memmove(t->sbuf, t->sbuf + acked, t->slen - acked);
            t->slen -= acked;
            t->snd_una = ack;
            t->rtx_t = now_ms();
            wake(); /* room in sbuf: read the host socket again */
        }
        t->snd_wnd = be16(s + 14);
    }
    if (t->state != T_EST) return;
    bool need_ack = false;
    if (dl) {
        need_ack = true;
        if (seq == t->rcv_nxt && !t->guest_fin) {
            ssize_t n = send(t->fd, data, dl, 0);
            if (n < 0 && errno != EAGAIN) {
                tcp_send(t, TH_RST | TH_ACK, t->snd_nxt, NULL, 0);
                tcb_free(t);
                return;
            }
            if (n > 0) t->rcv_nxt += (uint32_t)n;
            if (n < (ssize_t)dl) wake(); /* the host is full; the guest retransmits the rest */
        }
    }
    if (flags & TH_FIN) {
        need_ack = true;
        if (!t->guest_fin && seq + (uint32_t)dl == t->rcv_nxt) {
            t->rcv_nxt++;
            t->guest_fin = true;
            shutdown(t->fd, SHUT_WR);
        }
    }
    if (need_ack) tcp_send(t, TH_ACK, t->snd_nxt, NULL, 0);
    tcp_push(t);
    if (t->guest_fin && t->fin_acked) tcb_free(t);
}

static void tcp_connected(struct tcb *t)
{
    int err = 0;
    socklen_t l = sizeof err;
    getsockopt(t->fd, SOL_SOCKET, SO_ERROR, &err, &l);
    if (err) {
        if (dbg) LOGE("net: tcp connect failed: %s\n", strerror(err));
        tcp_send(t, TH_RST | TH_ACK, 0, NULL, 0);
        tcb_free(t);
        return;
    }
    t->state = T_SYN_RCVD;
    t->snd_nxt = t->iss + 1;
    t->rtx_t = now_ms();
    tcp_send(t, TH_SYN | TH_ACK, t->iss, NULL, 0);
}

static void tcp_readable(struct tcb *t)
{
    if (t->slen >= SBUF || t->host_eof) return;
    ssize_t n = recv(t->fd, t->sbuf + t->slen, SBUF - t->slen, 0);
    if (n == 0) t->host_eof = true;
    else if (n < 0) {
        if (errno == EAGAIN) return;
        tcp_send(t, TH_RST | TH_ACK, t->snd_nxt, NULL, 0);
        tcb_free(t);
        return;
    } else t->slen += (size_t)n;
    tcp_push(t);
}

static void tcp_timers(uint64_t now)
{
    for (int i = 0; i < NTCP; i++) {
        struct tcb *t = &tcbs[i];
        if (!t->state) continue;
        if (now - t->idle_t > 300000) { /* 5 minutes without a segment either way */
            if (t->state != T_CONNECTING) tcp_send(t, TH_RST | TH_ACK, t->snd_nxt, NULL, 0);
            tcb_free(t);
            continue;
        }
        if (t->state == T_SYN_SENT && now - t->syn_t > 10000) { /* the guest never answered */
            if (dbg) LOGE("net: forward to guest port %d timed out\n", t->gport);
            tcb_free(t);
            continue;
        }
        if (t->state == T_CONNECTING || now - t->rtx_t < RTO_MS) continue;
        if (t->state == T_SYN_SENT) {
            t->rtx_t = now;
            tcp_send(t, TH_SYN, t->iss, NULL, 0);
        } else if (t->state == T_SYN_RCVD) {
            t->rtx_t = now;
            tcp_send(t, TH_SYN | TH_ACK, t->iss, NULL, 0);
        } else if (t->snd_nxt != t->snd_una) { /* go back N */
            t->snd_nxt = t->snd_una;
            if (!t->fin_acked) t->fin_sent = false;
            tcp_push(t);
            t->rtx_t = now;
        } else if (t->snd_wnd == 0 && t->slen) { /* zero-window probe */
            tcp_send(t, TH_ACK, t->snd_nxt, t->sbuf, 1);
            t->rtx_t = now;
        }
    }
}

/* ---- inbound port forwarding ------------------------------------------- */
#define NFWD 16
static struct fwd { uint32_t bind; int hport, gport, fd; } fwds[NFWD];
static int nfwd;
static uint16_t fwd_port = 40000;

/* "[addr:]hostport:guestport"; addr defaults to 127.0.0.1. Implies --net. */
bool net_add_forward(const char *spec)
{
    char buf[128], *parts[3];
    int n = 0;
    if (nfwd == NFWD || strlen(spec) >= sizeof buf) return false;
    strcpy(buf, spec);
    for (char *p = buf, *tok; (tok = strsep(&p, ":")); ) { if (n == 3) return false; parts[n++] = tok; }
    if (n < 2) return false;
    struct fwd *f = &fwds[nfwd];
    struct in_addr a = {htonl(IP4(127, 0, 0, 1))};
    if (n == 3 && !inet_aton(parts[0], &a)) return false;
    char *e1, *e2;
    long hp = strtol(parts[n - 2], &e1, 10), gp = strtol(parts[n - 1], &e2, 10);
    if (*e1 || *e2 || hp < 1 || hp > 65535 || gp < 1 || gp > 65535) return false;
    f->bind = ntohl(a.s_addr); f->hport = (int)hp; f->gport = (int)gp; f->fd = -1;
    nfwd++;
    g.net = true;
    return true;
}

static void fwd_listen(void)
{
    for (int i = 0; i < nfwd; i++) {
        struct fwd *f = &fwds[i];
        int fd = nb_socket(SOCK_STREAM, 0), one = 1;
        if (fd < 0) continue;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a = {0};
        a.sin_len = sizeof a; a.sin_family = AF_INET;
        a.sin_port = htons((uint16_t)f->hport); a.sin_addr.s_addr = htonl(f->bind);
        if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 16) < 0) {
            LOGE("net: cannot forward host port %d: %s\n", f->hport, strerror(errno));
            close(fd);
            continue;
        }
        f->fd = fd;
        if (dbg) LOGE("net: forwarding host port %d to guest port %d\n", f->hport, f->gport);
    }
}

/* A host client connected: open a connection to the guest from 10.0.2.2. */
static void fwd_accept(struct fwd *f)
{
    int fd = accept(f->fd, NULL, NULL);
    if (fd < 0) return;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    struct tcb *t = NULL;
    for (int i = 0; i < NTCP; i++) if (!tcbs[i].state) { t = &tcbs[i]; break; }
    if (!t) { close(fd); return; }
    int port = 0;
    for (int tries = 0; tries < 30000 && !port; tries++) {
        int p = fwd_port;
        fwd_port = fwd_port >= 48999 ? 40000 : fwd_port + 1;
        bool used = false;
        for (int i = 0; i < NTCP; i++)
            if (tcbs[i].state && tcbs[i].rip == NET_GW && tcbs[i].rport == p && tcbs[i].gport == f->gport) used = true;
        if (!used) port = p;
    }
    if (!port) { close(fd); return; }
    memset(t, 0, sizeof *t);
    t->state = T_SYN_SENT; t->fd = fd;
    t->rip = NET_GW; t->rport = port; t->gport = f->gport;
    t->iss = arc4random();
    t->snd_una = t->iss; t->snd_nxt = t->iss + 1;
    t->sbuf = malloc(SBUF);
    t->idle_t = t->rtx_t = t->syn_t = now_ms();
    stat_tcp_conns++;
    if (dbg) LOGE("net: forward host port %d -> guest port %d (from 10.0.2.2:%d)\n", f->hport, f->gport, port);
    tcp_send(t, TH_SYN, t->iss, NULL, 0);
}

/* ---- IP ----------------------------------------------------------------- */
static void ip_input(uint8_t *ip, size_t len)
{
    if (len < 20 || (ip[0] >> 4) != 4) return;
    size_t hl = (ip[0] & 15) * 4u, tl = be16(ip + 2);
    if (hl < 20 || tl < hl || tl > len) return;
    if (be16(ip + 6) & 0x3fff) return; /* fragments are not reassembled */
    uint32_t src = be32(ip + 12), dst = be32(ip + 16);
    int proto = ip[9];
    uint8_t *p = ip + hl;
    size_t pl = tl - hl;
    if (dbg) {
        uint16_t c = csum_fold(csum_add(0, ip, hl)), c2 = 0;
        if (proto == 6 || proto == 17) c2 = csum_fold(csum_add(pseudo(src, dst, proto, pl), p, pl));
        if (proto == 1) c2 = csum_fold(csum_add(0, p, pl));
        if (proto == 17 && pl >= 8 && be16(p + 6) == 0) c2 = 0;
        if (c || c2) LOGE("net: bad guest checksum proto %d (ip %04x, payload %04x)\n", proto, c, c2);
        if (proto == 6 && pl >= 20)
            LOGE("net: tx tcp %d->%d flags %02x seq %u ack %u win %u len %zu\n", be16(p), be16(p + 2), p[13], be32(p + 4), be32(p + 8), be16(p + 14), pl - (p[12] >> 4) * 4);
    }
    if (proto == 1) icmp_input(src, dst, p, pl);
    else if (proto == 17) udp_input(src, dst, p, pl);
    else if (proto == 6) tcp_input(src, dst, p, pl);
}

static void eth_input(uint8_t *f, size_t len)
{
    if (len < 14) return;
    int type = be16(f + 12);
    if (type == 0x0806) arp_input(f, len);
    else if (type == 0x0800) ip_input(f + 14, len - 14);
}

/* ---- poll thread -------------------------------------------------------- */
static void *net_main(void *arg)
{
    enum { K_TCP, K_UDP, K_PING, K_FWD };
    struct pollfd pf[1 + NTCP + NUDP + NPING + NFWD];
    struct { int kind, idx, fd; } who[1 + NTCP + NUDP + NPING + NFWD];
    uint64_t last_timer = 0;
    while (!atomic_load(&g.stop)) {
        int n = 1;
        pf[0].fd = wake_pipe[0]; pf[0].events = POLLIN;
        pthread_mutex_lock(&g.lock);
        for (int i = 0; i < NTCP; i++) {
            struct tcb *t = &tcbs[i];
            if (!t->state) continue;
            short ev = t->state == T_CONNECTING ? POLLOUT : (!t->host_eof && t->slen < SBUF ? POLLIN : 0);
            if (!ev) continue;
            pf[n].fd = t->fd; pf[n].events = ev;
            who[n].kind = K_TCP; who[n].idx = i; who[n].fd = t->fd; n++;
        }
        for (int i = 0; i < NUDP; i++)
            if (udps[i].fd > 0) { pf[n].fd = udps[i].fd; pf[n].events = POLLIN; who[n].kind = K_UDP; who[n].idx = i; who[n].fd = udps[i].fd; n++; }
        for (int i = 0; i < NPING; i++)
            if (pings[i].fd > 0) { pf[n].fd = pings[i].fd; pf[n].events = POLLIN; who[n].kind = K_PING; who[n].idx = i; who[n].fd = pings[i].fd; n++; }
        for (int i = 0; i < nfwd; i++)
            if (fwds[i].fd >= 0) { pf[n].fd = fwds[i].fd; pf[n].events = POLLIN; who[n].kind = K_FWD; who[n].idx = i; who[n].fd = fwds[i].fd; n++; }
        pthread_mutex_unlock(&g.lock);
        for (int i = 0; i < n; i++) pf[i].revents = 0;
        poll(pf, (nfds_t)n, 50);
        if (pf[0].revents) { char b[64]; (void)!read(wake_pipe[0], b, sizeof b); }
        pthread_mutex_lock(&g.lock);
        for (int i = 1; i < n; i++) {
            if (!pf[i].revents) continue;
            if (who[i].kind == K_TCP) {
                struct tcb *t = &tcbs[who[i].idx];
                if (!t->state || t->fd != who[i].fd) continue;
                if (t->state == T_CONNECTING) tcp_connected(t);
                else tcp_readable(t);
            } else if (who[i].kind == K_UDP) {
                if (udps[who[i].idx].fd == who[i].fd) udp_readable(&udps[who[i].idx]);
            } else if (who[i].kind == K_FWD) {
                fwd_accept(&fwds[who[i].idx]);
            } else if (pings[who[i].idx].fd == who[i].fd) ping_readable(&pings[who[i].idx]);
        }
        uint64_t now = now_ms();
        if (now - last_timer >= 50) {
            last_timer = now;
            tcp_timers(now);
            for (int i = 0; i < NUDP; i++)
                if (udps[i].fd > 0 && now - udps[i].t > 60000) { close(udps[i].fd); udps[i].fd = 0; }
            for (int i = 0; i < NPING; i++)
                if (pings[i].fd > 0 && now - pings[i].t > 5000) { close(pings[i].fd); pings[i].fd = 0; }
        }
        rx_flush();
        pthread_mutex_unlock(&g.lock);
    }
    return NULL;
}

void net_start(void)
{
    if (!g.net) return;
    dbg = getenv("COOLVM_NET_DEBUG") != NULL;
    signal(SIGPIPE, SIG_IGN);
    if (pipe(wake_pipe) == 0) {
        fcntl(wake_pipe[0], F_SETFL, O_NONBLOCK);
        fcntl(wake_pipe[1], F_SETFL, O_NONBLOCK);
        fcntl(wake_pipe[0], F_SETFD, FD_CLOEXEC);
        fcntl(wake_pipe[1], F_SETFD, FD_CLOEXEC);
    }
    fwd_listen();
    pthread_t th;
    pthread_create(&th, NULL, net_main, NULL);
    pthread_detach(th);
}

void net_report(void)
{
    if (g.net && dbg)
        LOGE("net: %llu frames from the guest, %llu to it, %llu dropped, %llu tcp connections\n",
             (unsigned long long)stat_tx, (unsigned long long)stat_rx, (unsigned long long)stat_rxdrop,
             (unsigned long long)stat_tcp_conns);
}
