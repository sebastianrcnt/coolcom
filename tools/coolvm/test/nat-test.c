// Host-side test of coolvm's user-mode NAT (src/net.c) without a VM: this
// program plays the guest's virtio-net driver on a fake RAM block and sends
// ARP, ICMP echo to the gateway, DHCP DISCOVER, a DNS query for example.com and
// an HTTP GET over TCP. Exit 0 = pass, 77 = host offline (DNS failed), 1 = fail.
#include "coolvm.h"
#include <unistd.h>
struct vm g;
void aic_update_locked(void) {}
static uint8_t *R(uint64_t pa) { return g.ram + (pa - DRAM_BASE); }
#define QN 16
static uint64_t rxd = DRAM_BASE + 0x1000, rxa = DRAM_BASE + 0x2000, rxu = DRAM_BASE + 0x3000;
static uint64_t txd = DRAM_BASE + 0x4000, txa = DRAM_BASE + 0x5000, txu = DRAM_BASE + 0x6000;
static uint64_t rxbuf = DRAM_BASE + 0x10000, txbuf = DRAM_BASE + 0x40000;
static uint16_t rx_used_seen, tx_avail;
static void w(uint64_t off, uint64_t v) { pthread_mutex_lock(&g.lock); net_mmio(off, 4, true, &v); pthread_mutex_unlock(&g.lock); }
static void desc(uint64_t d, int i, uint64_t a, uint32_t l, uint16_t f) { uint8_t *p = R(d + 16 * i); memcpy(p, &a, 8); memcpy(p + 8, &l, 4); memcpy(p + 12, &f, 2); memset(p + 14, 0, 2); }
static uint16_t rd16(uint64_t pa) { uint16_t v; memcpy(&v, R(pa), 2); return v; }
static void wr16(uint64_t pa, uint16_t v) { memcpy(R(pa), &v, 2); }
static void setup(void)
{
    w(0x70, 1); w(0x70, 3); w(0x24, 1); w(0x20, 1); w(0x70, 11);
    for (int q = 0; q < 2; q++) {
        w(0x30, q); w(0x38, QN);
        w(0x80, q ? txd : rxd); w(0x84, (q ? txd : rxd) >> 32);
        w(0x90, q ? txa : rxa); w(0x94, (q ? txa : rxa) >> 32);
        w(0xa0, q ? txu : rxu); w(0xa4, (q ? txu : rxu) >> 32);
        w(0x44, 1);
    }
    for (int i = 0; i < QN; i++) { desc(rxd, i, rxbuf + 2048 * i, 2048, 2); wr16(rxa + 4 + 2 * i, i); }
    wr16(rxa + 2, QN);
    w(0x70, 15);
}
static void send_frame(const uint8_t *f, size_t len)
{
    int i = tx_avail % QN;
    uint8_t *b = R(txbuf + 2048 * i);
    memset(b, 0, 12); memcpy(b + 12, f, len);
    desc(txd, i, txbuf + 2048 * i, 12 + len, 0);
    wr16(txa + 4 + 2 * i, i);
    wr16(txa + 2, ++tx_avail);
    w(0x50, 1);
}
static uint16_t rx_avail = QN;
static int recv_frame(uint8_t *f, int ms)
{
    for (int t = 0; t < ms; t++) {
        if (rd16(rxu + 2) != rx_used_seen) {
            uint8_t *e = R(rxu + 4 + 8 * (rx_used_seen % QN));
            uint32_t id, len; memcpy(&id, e, 4); memcpy(&len, e + 4, 4);
            memcpy(f, R(rxbuf + 2048 * id) + 12, len - 12);
            rx_used_seen++;
            wr16(rxa + 4 + 2 * (rx_avail % QN), id); wr16(rxa + 2, ++rx_avail);
            w(0x50, 0);
            return len - 12;
        }
        usleep(1000);
    }
    return -1;
}
static uint32_t cs(const uint8_t *p, size_t n, uint32_t s) { for (; n > 1; n -= 2, p += 2) s += p[0] << 8 | p[1]; if (n) s += p[0] << 8; return s; }
static uint16_t fold(uint32_t s) { while (s >> 16) s = (s & 0xffff) + (s >> 16); return ~s; }
static uint8_t gm[6] = {0x52, 0x54, 0, 0x12, 0x34, 0x56}, gw[6] = {0x52, 0x55, 10, 0, 2, 2};
static size_t ipf(uint8_t *f, int proto, uint32_t dst, const uint8_t *pl, size_t n)
{
    memcpy(f, gw, 6); memcpy(f + 6, gm, 6); f[12] = 8; f[13] = 0;
    uint8_t *ip = f + 14; memset(ip, 0, 20);
    ip[0] = 0x45; ip[2] = (20 + n) >> 8; ip[3] = 20 + n; ip[8] = 64; ip[9] = proto;
    uint32_t src = 0x0a00020f;
    ip[12] = 10; ip[13] = 0; ip[14] = 2; ip[15] = 15;
    ip[16] = dst >> 24; ip[17] = dst >> 16; ip[18] = dst >> 8; ip[19] = dst;
    uint16_t c = fold(cs(ip, 20, 0)); ip[10] = c >> 8; ip[11] = c;
    memcpy(ip + 20, pl, n);
    if (proto != 1) {
        uint32_t ps = (src >> 16) + (src & 0xffff) + (dst >> 16) + (dst & 0xffff) + proto + n;
        int co = proto == 6 ? 16 : 6;
        ip[20 + co] = ip[21 + co] = 0;
        c = fold(cs(ip + 20, n, ps)); ip[20 + co] = c >> 8; ip[21 + co] = c;
    }
    return 34 + n;
}
static uint32_t seq = 1000, ack;
static void tcp(uint32_t dst, int flags, const char *data)
{
    uint8_t s[1500] = {0}, f[1600];
    size_t n = data ? strlen(data) : 0;
    s[0] = 40000 >> 8; s[1] = 40000 & 255; s[2] = 0; s[3] = 80;
    s[4] = seq >> 24; s[5] = seq >> 16; s[6] = seq >> 8; s[7] = seq;
    s[8] = ack >> 24; s[9] = ack >> 16; s[10] = ack >> 8; s[11] = ack;
    s[12] = 5 << 4; s[13] = flags; s[14] = 0x20; s[15] = 0;
    memcpy(s + 20, data, n);
    send_frame(f, ipf(f, 6, dst, s, 20 + n));
    seq += n + ((flags & 3) ? 1 : 0);
}
int main(int argc, char **argv)
{
    g.ram_size = 1 << 20; g.ram = calloc(1, g.ram_size); g.net = true;
    pthread_mutex_init(&g.lock, NULL);
    if (argc > 1) setenv("COOLVM_NET_DEBUG", "1", 1);
    net_start(); setup();
    uint8_t f[2048], u[600] = {0}; int n;
    // ARP for gateway
    uint8_t arp[42] = {0xff,0xff,0xff,0xff,0xff,0xff, 0x52,0x54,0,0x12,0x34,0x56, 8,6, 0,1,8,0,6,4,0,1, 0x52,0x54,0,0x12,0x34,0x56, 10,0,2,15, 0,0,0,0,0,0, 10,0,2,2};
    send_frame(arp, 42);
    n = recv_frame(f, 1000); printf("arp reply len %d op %d\n", n, f[21]);
    if (n != 42 || f[21] != 2) return 1;
    uint8_t echo[12] = {8, 0, 0, 0, 0, 7, 0, 1, 'p', 'i', 'n', 'g'};
    uint16_t ec = fold(cs(echo, 12, 0)); echo[2] = ec >> 8; echo[3] = ec;
    send_frame(f, ipf(f, 1, 0x0a000202, echo, 12));
    n = recv_frame(f, 1000); printf("icmp reply type %d id %d\n", f[34], f[39]);
    if (n != 46 || f[34] != 0 || f[39] != 7 || fold(cs(f + 34, 12, 0))) return 1;
    uint8_t dh[300] = {1, 1, 6, 0, 1, 2, 3, 4};
    memcpy(dh + 28, gm, 6); dh[236] = 99; dh[237] = 130; dh[238] = 83; dh[239] = 99;
    dh[240] = 53; dh[241] = 1; dh[242] = 1; dh[243] = 255;
    memset(u, 0, sizeof u); u[1] = 68; u[3] = 67; u[4] = (8 + 300) >> 8; u[5] = (8 + 300) & 255; memcpy(u + 8, dh, 300);
    send_frame(f, ipf(f, 17, 0xffffffff, u, 308));
    n = recv_frame(f, 1000);
    printf("dhcp offer %d.%d.%d.%d type %d\n", f[58], f[59], f[60], f[61], f[42 + 242]);
    if (n < 0 || f[58] != 10 || f[61] != 15 || f[42 + 242] != 2) return 1;
    memset(u, 0, sizeof u);
    // DNS
    uint8_t q[] = {0x12,0x34,1,0,0,1,0,0,0,0,0,0, 7,'e','x','a','m','p','l','e',3,'c','o','m',0, 0,1,0,1};
    u[0] = 0x30; u[1] = 0x39; u[2] = 0; u[3] = 53; u[4] = 0; u[5] = 8 + sizeof q; memcpy(u + 8, q, sizeof q);
    send_frame(f, ipf(f, 17, 0x0a000203, u, 8 + sizeof q));
    n = recv_frame(f, 5000);
    if (n < 0) { printf("no dns\n"); return 1; }
    uint8_t *d = f + 42; int an = d[7];
    printf("dns an=%d rcode=%d\n", an, d[3] & 15);
    if (!an) { printf("host offline, skipping TCP\n"); return 77; }
    uint8_t *a = d + 12 + sizeof q - 12 + 12;
    uint32_t ip = a[0] << 24 | a[1] << 16 | a[2] << 8 | a[3];
    printf("example.com = %d.%d.%d.%d\n", a[0], a[1], a[2], a[3]);
    tcp(ip, 2, NULL);
    n = recv_frame(f, 5000);
    uint8_t *t = f + 34;
    printf("synack flags %02x\n", t[13]);
    ack = (t[4] << 24 | t[5] << 16 | t[6] << 8 | t[7]) + 1;
    tcp(ip, 16, NULL);
    tcp(ip, 0x18, "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n");
    static char page[65536];
    int total = 0;
    for (;;) {
        n = recv_frame(f, 5000);
        if (n < 0) break;
        t = f + 34;
        int hl = (t[12] >> 4) * 4, dl = (f[16] << 8 | f[17]) - 20 - hl;
        uint32_t s2 = t[4] << 24 | t[5] << 16 | t[6] << 8 | t[7];
        if (s2 == ack) { if (total + dl < (int)sizeof page - 1) memcpy(page + total, t + hl, dl); total += dl; ack += dl; if (t[13] & 1) ack++; }
        tcp(ip, 16, NULL);
        if (t[13] & 1) { tcp(ip, 17, NULL); break; }
    }
    printf("http: %d bytes\n", total);
    return total > 0 && strstr(page, "Example Domain") ? 0 : 1;
}
