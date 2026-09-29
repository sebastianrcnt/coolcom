// Remote shell: ShellServe(port) accepts TCP connections and gives each one an
// independent shell task (its own compiler and terminal, like a Tmux pane).
// The terminal's output is streamed to the client as it is printed (a CVTerm
// sink), \n as \r\n; the client's bytes are decoded into key events (ANSI
// sequences, Ctrl+letter, UTF-8) like the UART's. Telnet clients are told
// WILL ECHO / WILL SGA (character mode, the shell echoes) and DO NAWS (the
// window size becomes the terminal size); the negotiation bytes are cleared
// from the line for clients that are not telnet. Ctrl+C breaks the running
// statement (Ctrl+Alt+C on the console); closing the connection kills the
// shell and everything it started.
//   coolvm --net-forward 2323:23 ...    then in the OS: ShellServe(23);
//   on the Mac: telnet localhost 2323, or tools/rsh.sh (nc with a raw tty)

#define RSH_OUT     65536
#define RSH_MAX     8
#define RSH_ESC_MS  50

class CRShell
{
    CTcb *tcb;
    CVTerm *v;
    CTask *shell;
    U8 *out;           // output ring, guarded by v->lock
    I64 ohead, olen, dropped;
    I64 kstate, knp, kpar[4], kalt, kcp, kleft, kdeadline;  // key decoder
    I64 tstate, sblen; // telnet: 0 data, 1 IAC, 2 option byte, 3 in SB, 4 IAC in SB
    U8 sb[16];
    Bool cr;
};
I64 rsh_count;

U0 RshPutOut(CRShell *s, U8 c)
{
    if (s->olen >= RSH_OUT) {
        s->dropped++;
        return;
    }
    s->out[(s->ohead + s->olen) % RSH_OUT] = c;
    s->olen++;
}

U0 RshSink(CVTerm *v, U8 c)
{//The terminal's sink: runs under v->lock with IRQs masked, so it only queues.
    CRShell *s = v->sink_data;
    if (c == '\n')
        RshPutOut(s, '\r');
    RshPutOut(s, c);
    if (c == 0xFF)
        RshPutOut(s, 0xFF);  // telnet IAC is doubled
}

U0 RshBreak(CRShell *s)
{//Ctrl+C: stop the shell's running statement, as Ctrl+Alt+C does on the console.
    CShell *sh;
    if (!TaskValidate(s->shell))
        return;
    sh = s->shell->shell_ctx;
    if (sh && sh->in_stmt)
        Kill(s->shell, FALSE, TRUE);
    else
        VtKeyPush(s->v, KF_CTRL | 'c');
}

U0 RshKey(CRShell *s, I64 ev)
{
    ev |= s->kalt;
    s->kalt = 0;
    if ((ev & ~KF_ALT) == (KF_CTRL | 'c'))
        RshBreak(s);
    else
        VtKeyPush(s->v, ev);
}

U0 RshSeq(CRShell *s, I64 fin)
{//The final byte of ESC [ ... or ESC O (the same keys as KeyUartSeq).
    I64 k = 0, n = s->kpar[0], f = 0;
    if (s->knp >= 2)
        f = KeyXtermMods(s->kpar[1]);
    else if (fin != '~' && n > 1)
        f = KeyXtermMods(n);
    switch (fin) {
        case 'A': k = KEY_UP; break;
        case 'B': k = KEY_DOWN; break;
        case 'C': k = KEY_RIGHT; break;
        case 'D': k = KEY_LEFT; break;
        case 'H': k = KEY_HOME; break;
        case 'F': k = KEY_END; break;
        case 'P': k = KEY_F1; break;
        case 'Q': k = KEY_F1 + 1; break;
        case 'R': k = KEY_F1 + 2; break;
        case 'S': k = KEY_F1 + 3; break;
        case 'Z':
            k = KEY_TAB;
            f |= KF_SHIFT;
            break;
        case '~':
            if (n == 1 || n == 7) k = KEY_HOME;
            else if (n == 2) k = KEY_INS;
            else if (n == 3) k = KEY_DEL;
            else if (n == 4 || n == 8) k = KEY_END;
            else if (n == 5) k = KEY_PGUP;
            else if (n == 6) k = KEY_PGDN;
            else if (n >= 11 && n <= 15) k = KEY_F1 + n - 11;
            else if (n >= 17 && n <= 21) k = KEY_F1 + 5 + n - 17;
            else if (n == 23 || n == 24) k = KEY_F1 + 10 + n - 23;
            break;
    }
    if (k)
        RshKey(s, k | f);
    else
        s->kalt = 0;
}

U0 RshKeyByte(CRShell *s, I64 b)
{//One byte of terminal input (telnet already removed).
    if (s->cr) {
        s->cr = FALSE;
        if (b == '\n' || !b)
            return;  // CR LF / CR NUL is one Enter
    }
    if (s->kstate == 1) {
        if (b == '[' || b == 'O') {
            s->kstate = 2;
            s->knp = 0;
            s->kpar[0] = s->kpar[1] = 0;
            return;
        }
        s->kstate = 0;
        s->kalt = KF_ALT;
    } else if (s->kstate == 2) {
        if (b >= '0' && b <= '9') {
            if (!s->knp)
                s->knp = 1;
            if (s->knp <= 4)
                s->kpar[s->knp - 1] = s->kpar[s->knp - 1] * 10 + b - '0';
        } else if (b == ';') {
            if (!s->knp)
                s->knp = 1;
            if (s->knp < 4)
                s->kpar[s->knp] = 0;
            s->knp++;
        } else if (b >= 0x40 && b <= 0x7E) {
            s->kstate = 0;
            RshSeq(s, b);
        } else {
            s->kstate = 0;
            s->kalt = 0;
        }
        return;
    }
    if (s->kleft) {
        if ((b & 0xC0) == 0x80) {
            s->kcp = (s->kcp << 6) | (b & 0x3F);
            if (!--s->kleft)
                RshKey(s, s->kcp);
            return;
        }
        s->kleft = 0;
    }
    if (b == 27) {
        s->kstate = 1;
        s->kdeadline = jiffies + RSH_ESC_MS;
    } else if (b == '\r') {
        s->cr = TRUE;
        RshKey(s, KEY_ENTER);
    } else if (b == '\n')
        RshKey(s, KEY_ENTER);
    else if (b == 9)
        RshKey(s, KEY_TAB);
    else if (b == 8 || b == 127)
        RshKey(s, KEY_BACKSPACE);
    else if (!b)
        RshKey(s, KF_CTRL | ' ');
    else if (b < 27)
        RshKey(s, KF_CTRL | ('a' + b - 1));
    else if (b < 32)
        RshKey(s, KF_CTRL | ku_ctrl_sym[b - 28]);
    else if (b < 0x80)
        RshKey(s, b);
    else if (Utf8Len(b) > 1) {
        s->kleft = Utf8Len(b) - 1;
        s->kcp = b & (0x7F >> (s->kleft + 1));
    } else
        s->kalt = 0;
}

U0 RshSubNeg(CRShell *s)
{//IAC SB ... IAC SE: NAWS (31) gives the client's window size.
    I64 cols, rows;
    if (s->sblen >= 5 && s->sb[0] == 31) {
        cols = s->sb[1] << 8 | s->sb[2];
        rows = s->sb[3] << 8 | s->sb[4];
        if (cols >= 20 && cols <= 500 && rows >= 5 && rows <= 300)
            VtResize(s->v, cols, rows);
    }
}

U0 RshByte(CRShell *s, I64 b)
{//Strip telnet commands, then decode keys.
    switch (s->tstate) {
        case 0:
            if (b == 0xFF)
                s->tstate = 1;
            else
                RshKeyByte(s, b);
            return;
        case 1:
            if (b == 0xFF) {
                s->tstate = 0;
                RshKeyByte(s, b);
            } else if (b >= 251 && b <= 254)
                s->tstate = 2;  // WILL WONT DO DONT: one option byte follows
            else if (b == 250) {
                s->tstate = 3;
                s->sblen = 0;
            } else
                s->tstate = 0;
            return;
        case 2:
            s->tstate = 0;
            return;
        case 3:
            if (b == 0xFF)
                s->tstate = 4;
            else if (s->sblen < 16)
                s->sb[s->sblen++] = b;
            return;
        case 4:
            if (b == 0xFF) {
                s->tstate = 3;
                if (s->sblen < 16)
                    s->sb[s->sblen++] = b;
            } else {
                s->tstate = 0;
                if (b == 240)
                    RshSubNeg(s);
            }
            return;
    }
}

U0 RshShellTask(CRShell *s)
{
    VtBind(Fs, s->v);
    s->v->owner = Fs;
    ShellTask(-1);
}

Bool RshFlush(CRShell *s)
{//Send the queued output; FALSE if the connection is gone.
    U8 buf[4096];
    I64 n, i, daif;
    while (TRUE) {
        daif = SpinLockIrq(&s->v->lock);
        n = MinI64(s->olen, 4096);
        for (i = 0; i < n; i++)
            buf[i] = s->out[(s->ohead + i) % RSH_OUT];
        s->ohead = (s->ohead + n) % RSH_OUT;
        s->olen -= n;
        SpinUnlockIrq(&s->v->lock, daif);
        if (!n)
            return TRUE;
        if (TcpSend(s->tcb, buf, n) != n)
            return FALSE;
    }
}

U0 RshSession(CRShell *s)
{//Relay one connection: output to the client, client bytes to the shell's key queue.
    U8 buf[512], a[16];
    I64 n, i, daif;
    // IAC WILL ECHO, IAC WILL SGA, IAC DO NAWS; then erase them for plain clients.
    TcpSend(s->tcb, "\xFF\xFB\x01\xFF\xFB\x03\xFF\xFD\x1F\r\x1b[K", 13);
    StrPrint(buf, "Cool remote shell on %s (Ctrl+C breaks a statement)\r\n", NetIpStr(a, net_ip));
    TcpSend(s->tcb, buf, StrLen(buf));
    s->shell = Spawn(&RshShellTask, s, "RShell", 0, NULL, SHELL_STACK);
    while (TRUE) {
        if (!RshFlush(s))
            break;
        n = TcpRecv(s->tcb, buf, 512, 10);
        if (n > 0)
            for (i = 0; i < n; i++)
                RshByte(s, buf[i]);
        else if (n != TCP_ERR_TIMEOUT || s->tcb->state == TCP_CLOSED)
            break;  // end of stream, reset or retransmission timeout
        if (s->kstate && jiffies >= s->kdeadline) {
            if (s->kstate == 1)
                RshKey(s, KEY_ESC);
            else if (s->kstate == 2 && !s->knp)
                RshKey(s, '[' | KF_ALT);
            s->kstate = 0;
            s->kalt = 0;
        }
        if (!TaskValidate(s->shell)) {
            RshFlush(s);
            break;  // the shell ended
        }
    }
    VtStop(s->v);  // kill the shell and whatever it started on this terminal
    daif = SpinLockIrq(&s->v->lock);
    s->v->sink = NULL;
    SpinUnlockIrq(&s->v->lock, daif);
    TcpClose(s->tcb);
    VtRelease(s->v);
    Free(s->out);
    Free(s);
    ArchAdd(&rsh_count, -1);
}

U0 RshListen(CTcb *l)
{
    CTcb *t;
    CRShell *s;
    while (TRUE) {
        t = TcpAccept(l);
        if (rsh_count >= RSH_MAX) {
            TcpSend(t, "too many remote shells\r\n", 24);
            TcpClose(t);
            t = NULL;
        }
        if (!t)
            goto rsh_next;
        ArchAdd(&rsh_count, 1);
        s = CAlloc(sizeof(CRShell));
        s->tcb = t;
        s->out = MAlloc(RSH_OUT);
        s->v = VtNew(80, 24);
        s->v->sink_data = s;
        s->v->sink = &RshSink;
        Spawn(&RshSession, s, "RShellNet");
rsh_next:
    }
}

CTask *ShellServe(I64 port = 23)
{//Serve independent shells on TCP port (in the background); Kill the returned task to stop listening.
    CTcb *l = TcpListen(port);
    if (!l) {
        Print("ShellServe: port %d is in use\n", port);
        return NULL;
    }
    Print("ShellServe: shells on port %d\n", port);
    return Spawn(&RshListen, l, "ShellServe");
}
