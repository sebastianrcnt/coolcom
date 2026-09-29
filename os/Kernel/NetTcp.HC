// TCP/IP, part 2: TCP (RFC 793/9293 state machine, simplified where it is safe).
// - Connect, listen/accept, send, receive, close; all eleven states.
// - Retransmission: RFC 6298 RTO (Karn's rule, 200 ms .. 16 s, doubled per
//   retry, 10 retries then the connection is dropped), go-back-N from
//   snd_una. Zero-window probes through the same timer.
// - Windows: the peer's window and a congestion window (slow start and
//   congestion avoidance, back to one segment after a timeout) bound what is
//   in flight; we advertise the free space of a 32 KiB receive ring and send a
//   window update when a read opens it by a segment or more.
// - Out-of-order segments are dropped (and answered with a duplicate ACK);
//   every data segment is acknowledged at once (no delayed ACKs, no Nagle).
// - Options: MSS only (no window scaling, timestamps or SACK).
// - TIME_WAIT lasts 1 s instead of 2 MSL.
// A CTcb belongs to the stack until TcpClose; it is freed once it is closed
// on both sides and the user closed it.
#define TCP_CLOSED     0
#define TCP_LISTEN     1
#define TCP_SYN_SENT   2
#define TCP_SYN_RCVD   3
#define TCP_EST        4
#define TCP_FIN_WAIT1  5
#define TCP_FIN_WAIT2  6
#define TCP_CLOSE_WAIT 7
#define TCP_CLOSING    8
#define TCP_LAST_ACK   9
#define TCP_TIME_WAIT  10

#define TCP_FIN 1
#define TCP_SYN 2
#define TCP_RST 4
#define TCP_PSH 8
#define TCP_ACK 16

#define TCP_SBUF     65536
#define TCP_RBUF     32768
#define TCP_MSS      1460
#define TCP_RTO_INIT 1000
#define TCP_RTO_MIN  200
#define TCP_RTO_MAX  16000
#define TCP_RETRIES  10
#define TCP_BACKLOG  8

#define TCP_ERR_REFUSED -1
#define TCP_ERR_RESET   -2
#define TCP_ERR_TIMEOUT -3
#define TCP_ERR_CLOSED  -4

class CTcb
{
    CTcb *next, *parent;  // parent: the listener of a connection not yet accepted
    I64 state, lip, lport, rip, rport;
    I64 iss, irs, snd_una, snd_nxt, snd_wnd, rcv_nxt, adv_wnd;
    I64 mss, cwnd, ssthresh;
    U8 *sbuf;        // bytes from snd_una on: sent and unacknowledged, then unsent
    I64 slen;
    U8 *rbuf;        // received, not yet read (ring)
    I64 rhead, rlen;
    I64 rto, srtt, rttvar, rtx_at, rtt_seq, rtt_start, retries, tw_at;
    I64 err;
    Bool fin_pending, fin_sent, rcv_fin, user_closed, acc_ready;
};

CTcb *tcp_list;

U8 *TcpStateName(I64 state)
{
    if (state == TCP_CLOSED) return "CLOSED";
    if (state == TCP_LISTEN) return "LISTEN";
    if (state == TCP_SYN_SENT) return "SYN_SENT";
    if (state == TCP_SYN_RCVD) return "SYN_RCVD";
    if (state == TCP_EST) return "ESTABLISHED";
    if (state == TCP_FIN_WAIT1) return "FIN_WAIT1";
    if (state == TCP_FIN_WAIT2) return "FIN_WAIT2";
    if (state == TCP_CLOSE_WAIT) return "CLOSE_WAIT";
    if (state == TCP_CLOSING) return "CLOSING";
    if (state == TCP_LAST_ACK) return "LAST_ACK";
    return "TIME_WAIT";
}

I64 SeqDiff(I64 a, I64 b)
{//a - b in sequence space (signed 32-bit).
    I64 d = (a - b) & 0xFFFFFFFF;
    if (d & 0x80000000)
        d -= 0x100000000;
    return d;
}

I64 SeqAdd(I64 a, I64 n)
{
    return (a + n) & 0xFFFFFFFF;
}

Bool NetPortFree(I64 port)
{
    CTcb *t = tcp_list;
    while (t) {
        if (t->lport == port)
            return FALSE;
        t = t->next;
    }
    return TRUE;
}

I64 TcpWnd(CTcb *t)
{
    return MinI64(TCP_RBUF - t->rlen, 65535);
}

U0 TcpSeg(CTcb *t, I64 flags, I64 seq, U8 *data = NULL, I64 len = 0)
{//Send one segment of t.
    U8 s[NET_IP_MAX];
    I64 hl = 20;
    if (flags & TCP_SYN)
        hl = 24;
    NetPut16(s, t->lport);
    NetPut16(s + 2, t->rport);
    NetPut32(s + 4, seq);
    if (flags & TCP_ACK)
        NetPut32(s + 8, t->rcv_nxt);
    else
        NetPut32(s + 8, 0);
    s[12] = (hl / 4) << 4;
    s[13] = flags;
    t->adv_wnd = TcpWnd(t);
    NetPut16(s + 14, t->adv_wnd);
    NetPut16(s + 16, 0);
    NetPut16(s + 18, 0);
    if (flags & TCP_SYN) {
        s[20] = 2;
        s[21] = 4;
        NetPut16(s + 22, TCP_MSS);
    }
    if (len)
        MemCpy(s + hl, data, len);
    NetPut16(s + 16, NetFold(NetSum(s, hl + len, NetPseudo(t->lip, t->rip, IP_P_TCP, hl + len))));
    IpSend(IP_P_TCP, t->rip, s, hl + len, t->lip);
    net_stats.tcp_tx++;
}

U0 TcpRstReply(I64 src, I64 dst, U8 *seg, I64 dl)
{//Answer a segment that has no connection (RFC 793 "reset generation").
    CTcb t;
    I64 flags = seg[13];
    if (flags & TCP_RST)
        return;
    MemSet(&t, 0, sizeof(CTcb));
    t.lip = dst;
    t.rip = src;
    t.lport = NetGet16(seg + 2);
    t.rport = NetGet16(seg);
    net_stats.tcp_rst++;
    if (flags & TCP_ACK)
        TcpSeg(&t, TCP_RST, NetGet32(seg + 8));
    else {
        t.rcv_nxt = SeqAdd(NetGet32(seg + 4), dl);
        if (flags & TCP_SYN)
            t.rcv_nxt = SeqAdd(t.rcv_nxt, 1);
        if (flags & TCP_FIN)
            t.rcv_nxt = SeqAdd(t.rcv_nxt, 1);
        TcpSeg(&t, TCP_RST | TCP_ACK, 0);
    }
}

CTcb *TcbNew(I64 state, I64 lip, I64 lport, I64 rip, I64 rport)
{
    CTcb *t = CAlloc(sizeof(CTcb));
    t->state = state;
    t->lip = lip;
    t->lport = lport;
    t->rip = rip;
    t->rport = rport;
    t->mss = 536;
    t->rto = TCP_RTO_INIT;
    t->iss = NetRand & 0xFFFFFFFF;
    t->snd_una = t->iss;
    t->snd_nxt = SeqAdd(t->iss, 1);
    t->cwnd = 4 * TCP_MSS;
    t->ssthresh = 65535;
    if (state != TCP_LISTEN) {
        t->sbuf = MAlloc(TCP_SBUF);
        t->rbuf = MAlloc(TCP_RBUF);
    }
    t->next = tcp_list;
    tcp_list = t;
    return t;
}

U0 TcbFree(CTcb *t)
{
    CTcb *prev = NULL, *cur = tcp_list;
    while (cur && cur != t) {
        prev = cur;
        cur = cur->next;
    }
    if (!cur)
        return;
    if (prev)
        prev->next = t->next;
    else
        tcp_list = t->next;
    Free(t->sbuf);
    Free(t->rbuf);
    Free(t);
}

U0 TcpMssOpt(CTcb *t, U8 *seg, I64 hl)
{//Take the peer's MSS option from a SYN.
    I64 i = 20, kind, olen;
    t->mss = 536;
    while (i < hl) {
        kind = seg[i];
        if (kind == 0)
            break;
        if (kind == 1)
            i++;
        else {
            if (i + 1 >= hl)
                break;
            olen = seg[i + 1];
            if (olen < 2)
                break;
            if (kind == 2 && olen == 4 && i + 4 <= hl)
                t->mss = MinI64(NetGet16(seg + i + 2), TCP_MSS);
            i += olen;
        }
    }
    if (t->mss < 64)
        t->mss = 64;
}

U0 TcpDrop(CTcb *t, I64 err)
{//The connection is gone (reset, refused or timed out).
    t->state = TCP_CLOSED;
    t->err = err;
    t->rtx_at = 0;
}

U0 TcpOutput(CTcb *t, Bool probe = FALSE)
{//Send what the windows allow, then the FIN if the user closed.
    I64 inflight, unsent, wnd, n;
    if (t->state != TCP_EST && t->state != TCP_CLOSE_WAIT && t->state != TCP_FIN_WAIT1 &&
            t->state != TCP_CLOSING && t->state != TCP_LAST_ACK)
        return;
    while (!t->fin_sent) {
        inflight = SeqDiff(t->snd_nxt, t->snd_una);
        unsent = t->slen - inflight;
        if (unsent <= 0)
            break;
        wnd = MinI64(t->snd_wnd, t->cwnd) - inflight;
        if (wnd <= 0 && probe && !inflight)
            wnd = 1;  // zero-window probe
        if (wnd <= 0) {
            if (!t->rtx_at)
                t->rtx_at = jiffies + t->rto;  // persist timer
            break;
        }
        n = MinI64(MinI64(unsent, t->mss), wnd);
        TcpSeg(t, TCP_ACK | TCP_PSH, t->snd_nxt, t->sbuf + inflight, n);
        if (!t->rtx_at)
            t->rtx_at = jiffies + t->rto;
        if (!t->rtt_start) {
            t->rtt_start = jiffies + 1;  // + 1: 0 means none
            t->rtt_seq = SeqAdd(t->snd_nxt, n);
        }
        t->snd_nxt = SeqAdd(t->snd_nxt, n);
        probe = FALSE;
    }
    if (t->fin_pending && !t->fin_sent && SeqDiff(t->snd_nxt, t->snd_una) == t->slen) {
        TcpSeg(t, TCP_ACK | TCP_FIN, t->snd_nxt);
        t->snd_nxt = SeqAdd(t->snd_nxt, 1);
        t->fin_sent = TRUE;
        if (t->state == TCP_EST)
            t->state = TCP_FIN_WAIT1;
        else if (t->state == TCP_CLOSE_WAIT)
            t->state = TCP_LAST_ACK;
        if (!t->rtx_at)
            t->rtx_at = jiffies + t->rto;
    }
}

U0 TcpRttSample(CTcb *t, I64 r)
{//RFC 6298 in milliseconds (a jiffy is 1 ms).
    if (!t->srtt) {
        t->srtt = MaxI64(r, 1);
        t->rttvar = t->srtt / 2;
    } else {
        t->rttvar = (3 * t->rttvar + AbsI64(t->srtt - r)) / 4;
        t->srtt = (7 * t->srtt + r) / 8;
    }
    t->rto = t->srtt + MaxI64(10, 4 * t->rttvar);
    if (t->rto < TCP_RTO_MIN) t->rto = TCP_RTO_MIN;
    if (t->rto > TCP_RTO_MAX) t->rto = TCP_RTO_MAX;
}

U0 TcpAck(CTcb *t, I64 ack, I64 win)
{//Process an acceptable ACK in a synchronized state.
    I64 acked;
    if (SeqDiff(ack, t->snd_una) > 0 && SeqDiff(ack, t->snd_nxt) <= 0) {
        acked = SeqDiff(ack, t->snd_una);
        if (t->fin_sent && ack == t->snd_nxt)
            acked--;  // the FIN
        if (acked > t->slen)
            acked = t->slen;
        if (acked > 0) {
            MemCpy(t->sbuf, t->sbuf + acked, t->slen - acked);
            t->slen -= acked;
        }
        t->snd_una = ack;
        if (t->rtt_start && SeqDiff(ack, t->rtt_seq) >= 0) {
            TcpRttSample(t, jiffies + 1 - t->rtt_start);
            t->rtt_start = 0;
        }
        if (t->cwnd < t->ssthresh)
            t->cwnd += t->mss;
        else
            t->cwnd += MaxI64(1, t->mss * t->mss / t->cwnd);
        if (t->cwnd > 1 << 20)
            t->cwnd = 1 << 20;
        t->retries = 0;
        if (t->snd_una != t->snd_nxt)
            t->rtx_at = jiffies + t->rto;
        else
            t->rtx_at = 0;
    }
    if (SeqDiff(ack, t->snd_una) >= 0)
        t->snd_wnd = win;
}

Bool TcpFinAcked(CTcb *t)
{
    return t->fin_sent && t->snd_una == t->snd_nxt;
}

U0 TcpRx(I64 src, I64 dst, U8 *seg, I64 len)
{
    I64 sport, dport, seq, ack, hl, flags, win, dl, off, n, i, pos;
    U8 *data;
    Bool need_ack = FALSE;
    CTcb *t, *l = NULL, *c;
    if (len < 20 || NetFold(NetSum(seg, len, NetPseudo(src, dst, IP_P_TCP, len)))) {
        net_stats.csum_bad++;
        return;
    }
    hl = (seg[12] >> 4) * 4;
    if (hl < 20 || hl > len)
        return;
    net_stats.tcp_rx++;
    sport = NetGet16(seg);
    dport = NetGet16(seg + 2);
    seq = NetGet32(seg + 4);
    ack = NetGet32(seg + 8);
    flags = seg[13];
    win = NetGet16(seg + 14);
    data = seg + hl;
    dl = len - hl;
    for (t = tcp_list; t; t = t->next) {
        if (t->lport == dport) {
            if (t->state == TCP_LISTEN) {
                if (!l)
                    l = t;
            } else if (t->state != TCP_CLOSED && t->rport == sport && t->rip == src)
                break;
        }
    }
    if (!t && l) {
        if (flags & TCP_RST)
            return;
        if (flags & TCP_ACK) {
            TcpRstReply(src, dst, seg, dl);
            return;
        }
        if (!(flags & TCP_SYN))
            return;
        n = 0;
        for (c = tcp_list; c; c = c->next)
            if (c->parent == l)
                n++;
        if (n >= TCP_BACKLOG)
            return;
        c = TcbNew(TCP_SYN_RCVD, dst, dport, src, sport);
        c->parent = l;
        c->irs = seq;
        c->rcv_nxt = SeqAdd(seq, 1);
        c->snd_wnd = win;
        TcpMssOpt(c, seg, hl);
        TcpSeg(c, TCP_SYN | TCP_ACK, c->iss);
        c->rtx_at = jiffies + c->rto;
        return;
    }
    if (!t) {
        TcpRstReply(src, dst, seg, dl);
        return;
    }
    if (t->state == TCP_SYN_SENT) {
        if ((flags & TCP_ACK) && ack != SeqAdd(t->iss, 1)) {
            TcpRstReply(src, dst, seg, dl);
            return;
        }
        if (flags & TCP_RST) {
            if (flags & TCP_ACK)
                TcpDrop(t, TCP_ERR_REFUSED);
            return;
        }
        if (!(flags & TCP_SYN))
            return;
        t->irs = seq;
        t->rcv_nxt = SeqAdd(seq, 1);
        t->snd_wnd = win;
        TcpMssOpt(t, seg, hl);
        if (flags & TCP_ACK) {
            t->snd_una = ack;
            t->state = TCP_EST;
            t->rtx_at = 0;
            t->retries = 0;
            if (t->rtt_start) {
                TcpRttSample(t, jiffies + 1 - t->rtt_start);
                t->rtt_start = 0;
            }
            TcpSeg(t, TCP_ACK, t->snd_nxt);
            TcpOutput(t);
        } else {  // simultaneous open
            t->state = TCP_SYN_RCVD;
            TcpSeg(t, TCP_SYN | TCP_ACK, t->iss);
        }
        return;
    }
    // Synchronized states. Acceptability: RST and data must start in the window.
    off = SeqDiff(seq, t->rcv_nxt);
    if (flags & TCP_RST) {
        if (off >= 0 && off < MaxI64(TcpWnd(t), 1)) {
            net_stats.tcp_rst++;
            if (t->parent)
                t->user_closed = TRUE;  // never accepted: just forget it
            TcpDrop(t, TCP_ERR_RESET);
        }
        return;
    }
    if (flags & TCP_SYN) {
        if (t->state == TCP_SYN_RCVD && seq == t->irs)
            TcpSeg(t, TCP_SYN | TCP_ACK, t->iss);  // our SYN-ACK was lost
        else
            TcpSeg(t, TCP_ACK, t->snd_nxt);
        return;
    }
    if (!(flags & TCP_ACK))
        return;
    if (t->state == TCP_SYN_RCVD) {
        if (ack != SeqAdd(t->iss, 1)) {
            TcpRstReply(src, dst, seg, dl);
            return;
        }
        t->state = TCP_EST;
        t->snd_una = ack;
        t->snd_wnd = win;
        t->rtx_at = 0;
        t->retries = 0;
        if (t->parent)
            t->acc_ready = TRUE;
    }
    TcpAck(t, ack, win);
    if (TcpFinAcked(t)) {
        if (t->state == TCP_FIN_WAIT1)
            t->state = TCP_FIN_WAIT2;
        else if (t->state == TCP_CLOSING) {
            t->state = TCP_TIME_WAIT;
            t->tw_at = jiffies + 1000;
        } else if (t->state == TCP_LAST_ACK) {
            TcpDrop(t, 0);
            return;
        }
    }
    if (dl > 0) {
        need_ack = TRUE;
        if (!t->rcv_fin && off <= 0 && -off < dl &&
                (t->state == TCP_EST || t->state == TCP_FIN_WAIT1 || t->state == TCP_FIN_WAIT2)) {
            n = MinI64(dl + off, TCP_RBUF - t->rlen);  // off <= 0 skips what we already have
            pos = (t->rhead + t->rlen) % TCP_RBUF;
            for (i = 0; i < n; i++) {
                t->rbuf[pos] = data[i - off];
                if (++pos == TCP_RBUF)
                    pos = 0;
            }
            t->rlen += n;
            t->rcv_nxt = SeqAdd(t->rcv_nxt, n);
        }
    }
    if (flags & TCP_FIN) {
        need_ack = TRUE;
        if (!t->rcv_fin && SeqAdd(seq, dl) == t->rcv_nxt) {
            t->rcv_nxt = SeqAdd(t->rcv_nxt, 1);
            t->rcv_fin = TRUE;
            if (t->state == TCP_EST)
                t->state = TCP_CLOSE_WAIT;
            else if (t->state == TCP_FIN_WAIT1) {
                if (TcpFinAcked(t)) {
                    t->state = TCP_TIME_WAIT;
                    t->tw_at = jiffies + 1000;
                } else
                    t->state = TCP_CLOSING;
            } else if (t->state == TCP_FIN_WAIT2) {
                t->state = TCP_TIME_WAIT;
                t->tw_at = jiffies + 1000;
            }
        }
    }
    if (need_ack)
        TcpSeg(t, TCP_ACK, t->snd_nxt);
    TcpOutput(t);
}

U0 TcpTimers()
{//Retransmissions, persist probes, TIME_WAIT and freeing. Caller holds net_lock.
    CTcb *t = tcp_list, *nxt;
    while (t) {
        nxt = t->next;
        if (t->state == TCP_TIME_WAIT && jiffies >= t->tw_at)
            TcpDrop(t, 0);
        if (t->state == TCP_CLOSED) {
            if (t->user_closed)
                TcbFree(t);
        } else if (t->rtx_at && jiffies >= t->rtx_at) {
            if (t->state >= TCP_EST && !t->snd_wnd && t->slen) {
                // Persist: probe the zero window; this never gives up.
                t->rto = MinI64(t->rto * 2, TCP_RTO_MAX);
                t->rtx_at = jiffies + t->rto;
                t->snd_nxt = t->snd_una;
                TcpOutput(t, TRUE);
            } else if (++t->retries > TCP_RETRIES) {
                if (t->state != TCP_SYN_SENT)
                    TcpSeg(t, TCP_RST | TCP_ACK, t->snd_nxt);
                if (t->parent)
                    t->user_closed = TRUE;
                TcpDrop(t, TCP_ERR_TIMEOUT);
            } else {
                net_stats.tcp_retx++;
                t->rtt_start = 0;  // Karn: no samples from retransmitted data
                t->rto = MinI64(t->rto * 2, TCP_RTO_MAX);
                t->rtx_at = jiffies + t->rto;
                if (t->state == TCP_SYN_SENT)
                    TcpSeg(t, TCP_SYN, t->iss);
                else if (t->state == TCP_SYN_RCVD)
                    TcpSeg(t, TCP_SYN | TCP_ACK, t->iss);
                else {
                    if (t->snd_nxt != t->snd_una) {
                        t->ssthresh = MaxI64(SeqDiff(t->snd_nxt, t->snd_una) / 2, 2 * t->mss);
                        t->cwnd = t->mss;
                    }
                    t->snd_nxt = t->snd_una;  // go back N
                    if (t->fin_sent && !TcpFinAcked(t))
                        t->fin_sent = FALSE;
                    TcpOutput(t, TRUE);
                    if (t->snd_nxt == t->snd_una && !(t->slen && !t->snd_wnd))
                        t->rtx_at = 0;
                }
            }
        }
        t = nxt;
    }
}

// ---- the socket-like interface ------------------------------------------

CTcb *TcpConnect(I64 ip, I64 port, I64 timeout_ms = 10000)
{//Open a connection; NULL if refused, unreachable or timed out.
    CTcb *t;
    I64 daif, lip, deadline = jiffies + timeout_ms;
    daif = NetLock;
    lip = net_ip;
    if (((ip >> 24) & 0xFF) == 127)
        lip = ip;
    if (!lip) {
        NetUnlock(daif);
        return NULL;
    }
    t = TcbNew(TCP_SYN_SENT, lip, NetEphemeral, ip, port);
    t->user_closed = FALSE;
    TcpSeg(t, TCP_SYN, t->iss);
    t->rtx_at = jiffies + t->rto;
    t->rtt_start = jiffies + 1;
    NetUnlock(daif);
    while (TRUE) {
        daif = NetLock;
        if (t->state != TCP_SYN_SENT)
            break;
        if (jiffies >= deadline) {
            TcpDrop(t, TCP_ERR_TIMEOUT);
            break;
        }
        NetUnlock(daif);
        NetWait;
    }
    if (t->state == TCP_CLOSED) {
        t->user_closed = TRUE;
        NetUnlock(daif);
        return NULL;
    }
    NetUnlock(daif);
    return t;
}

CTcb *TcpListen(I64 port)
{//A listening socket for TcpAccept; NULL if the port is in use.
    CTcb *t;
    I64 daif = NetLock;
    if (!NetPortFree(port)) {
        NetUnlock(daif);
        return NULL;
    }
    t = TcbNew(TCP_LISTEN, 0, port, 0, 0);
    NetUnlock(daif);
    return t;
}

CTcb *TcpAccept(CTcb *l, I64 timeout_ms = -1)
{//The next established connection of listener l; NULL after timeout_ms.
    CTcb *t;
    I64 daif, deadline = jiffies + timeout_ms;
    while (TRUE) {
        daif = NetLock;
        for (t = tcp_list; t; t = t->next)
            if (t->parent == l && t->acc_ready) {
                t->parent = NULL;
                NetUnlock(daif);
                return t;
            }
        NetUnlock(daif);
        if (timeout_ms >= 0 && jiffies >= deadline)
            return NULL;
        NetWait;
    }
}

I64 TcpSend(CTcb *t, U8 *buf, I64 len, I64 timeout_ms = 30000)
{//Queue len bytes (waits while the send buffer is full); bytes queued or an error.
    I64 daif, n, done = 0, deadline = jiffies + timeout_ms;
    while (done < len) {
        daif = NetLock;
        if ((t->state != TCP_EST && t->state != TCP_CLOSE_WAIT) || t->fin_pending) {
            n = t->err;
            NetUnlock(daif);
            if (done)
                return done;
            if (n)
                return n;
            return TCP_ERR_CLOSED;
        }
        n = MinI64(len - done, TCP_SBUF - t->slen);
        if (n > 0) {
            MemCpy(t->sbuf + t->slen, buf + done, n);
            t->slen += n;
            done += n;
            TcpOutput(t);
        }
        NetUnlock(daif);
        if (done < len) {
            if (timeout_ms >= 0 && jiffies >= deadline)
                return done;
            NetWait;
        }
    }
    return done;
}

I64 TcpRecv(CTcb *t, U8 *buf, I64 max, I64 timeout_ms = -1)
{//Read up to max bytes: > 0 bytes, 0 at the end of the stream, < 0 an error or TCP_ERR_TIMEOUT.
    I64 daif, n, i, deadline = jiffies + timeout_ms;
    while (TRUE) {
        daif = NetLock;
        if (t->rlen) {
            n = MinI64(max, t->rlen);
            for (i = 0; i < n; i++) {
                buf[i] = t->rbuf[t->rhead];
                if (++t->rhead == TCP_RBUF)
                    t->rhead = 0;
            }
            t->rlen -= n;
            if (TcpWnd(t) - t->adv_wnd >= t->mss && t->state != TCP_CLOSED && !t->rcv_fin)
                TcpSeg(t, TCP_ACK, t->snd_nxt);  // window update
            NetUnlock(daif);
            return n;
        }
        if (t->rcv_fin || t->state == TCP_CLOSED) {
            n = t->err;
            NetUnlock(daif);
            return n;
        }
        NetUnlock(daif);
        if (timeout_ms >= 0 && jiffies >= deadline)
            return TCP_ERR_TIMEOUT;
        NetWait;
    }
}

U0 TcpClose(CTcb *t)
{//Close our side (FIN after the queued data) and give t back to the stack.
    CTcb *c;
    I64 daif = NetLock;
    t->user_closed = TRUE;
    if (t->state == TCP_LISTEN) {
        for (c = tcp_list; c; c = c->next)
            if (c->parent == t) {
                if (c->state != TCP_CLOSED)
                    TcpSeg(c, TCP_RST | TCP_ACK, c->snd_nxt);
                c->parent = NULL;
                c->user_closed = TRUE;
                TcpDrop(c, TCP_ERR_RESET);
            }
        TcpDrop(t, 0);
    } else if (t->state == TCP_SYN_SENT)
        TcpDrop(t, 0);
    else if (t->state == TCP_SYN_RCVD || t->state == TCP_EST || t->state == TCP_CLOSE_WAIT) {
        t->fin_pending = TRUE;
        if (t->state == TCP_SYN_RCVD) {
            TcpSeg(t, TCP_RST | TCP_ACK, t->snd_nxt);
            TcpDrop(t, 0);
        } else
            TcpOutput(t);
    }
    NetUnlock(daif);
}

I64 TcpState(CTcb *t)
{
    return t->state;
}
