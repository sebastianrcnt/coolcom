// Network test, run by DevTest under coolvm --net (tools/kernel-test.sh):
// DHCP from coolvm's NAT, ICMP to the gateway, UDP and TCP over loopback
// (listen/accept, both directions, orderly close), then DNS and an HTTP GET of
// http://example.com through the NAT. If DNS fails the host is taken to be
// offline and the external part is skipped.

U0 DevTestNet()
{
    I64 i, n, got, ip, src, sport, status, len, f0 = kt_fails;
    U8 *a, *b, buf[16], *res;
    CTcb *l, *c, *s;
    CUdpSock *u1, *u2;
    if (!net_nic) {
        KTFail("net: no NIC");
        return;
    }
    for (i = 0; i < 5000 && !net_ip; i++)
        Sleep(1);
    Print("net: address %s\n", NetIpStr(buf, net_ip));
    if (net_ip != 0x0A00020F || net_gw != 0x0A000202 || net_dns != 0x0A000203 || net_mask != 0xFFFFFF00) {
        KTFail("net: DHCP");
        return;
    }
    if (Ping("10.0.2.2", 1) != 1)
        KTFail("net: ping gateway");
    // UDP over loopback.
    u1 = UdpOpen(5555);
    u2 = UdpOpen;
    if (!u1 || !u2 || UdpOpen(5555)) {
        KTFail("net: UdpOpen");
        return;
    }
    UdpSend(u2, 0x7F000001, 5555, "hello udp", 9);
    MemSet(buf, 0, 16);
    n = UdpRecv(u1, buf, 16, &src, &sport, 1000);
    if (n != 9 || StrCmp(buf, "hello udp") || src != 0x7F000001 || sport != u2->port)
        KTFail("net: udp loopback");
    UdpClose(u1);
    UdpClose(u2);
    // TCP over loopback: 50000 bytes each way, more than the receive window.
    a = MAlloc(50000);
    b = MAlloc(50000);
    for (i = 0; i < 50000; i++)
        a[i] = (i * 7 + i / 256) & 0xFF;
    l = TcpListen(7777);
    if (!l || TcpListen(7777)) {
        KTFail("net: TcpListen");
        return;
    }
    c = TcpConnect(0x7F000001, 7777, 2000);
    s = TcpAccept(l, 2000);
    if (!c || !s) {
        KTFail("net: tcp connect/accept");
        return;
    }
    if (TcpConnect(0x7F000001, 7778, 2000))
        KTFail("net: connect to a closed port");
    // TcpSend queues up to 64 KiB, so one task can both send and receive.
    if (TcpSend(c, a, 50000) != 50000)
        KTFail("net: tcp send");
    for (got = 0; got < 50000 && (n = TcpRecv(s, b + got, 50000 - got, 3000)) > 0;)
        got += n;
    if (got != 50000 || MemCmp(a, b, 50000))
        KTFail("net: tcp client to server");
    for (i = 0; i < 50000; i++)
        a[i] = ~a[i];
    TcpSend(s, a, 50000);
    TcpClose(s);
    for (got = 0; got < 50000 && (n = TcpRecv(c, b + got, 50000 - got, 3000)) > 0;)
        got += n;
    if (got != 50000 || MemCmp(a, b, 50000))
        KTFail("net: tcp server to client");
    if (TcpRecv(c, b, 16, 2000) != 0)
        KTFail("net: tcp end of stream");
    TcpClose(c);
    TcpClose(l);
    Free(a);
    Free(b);
    if (kt_fails == f0)
        Print("net: loopback ok\n");
    // Through the NAT to the outside.
    if (!DnsResolve("example.com", &ip)) {
        Print("net: DNS failed, host offline? external tests skipped\n");
    } else {
        Print("net: example.com is %s\n", NetIpStr(buf, ip));
        res = HttpFetch("http://example.com/", &len, &status);
        if (!res || status != 200 || !StrFind("Example Domain", res))
            KTFail("net: http://example.com");
        else
            Print("net: HTTP %d, %d bytes from example.com\n", status, len);
        Free(res);
        if (HttpGet("http://example.com/") <= 0)
            KTFail("net: HttpGet");
    }
    NetRep;
    if (kt_fails == f0)
        Print("  net: PASS\n");
}
