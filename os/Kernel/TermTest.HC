// Exercise routing without touching the physical screen or consuming test keys.
U0 DevTestTerm()
{
    CVTerm *a = VtNew(8, 3), *b = VtNew(8, 3), *old = VtCurrent;
    I64 f0 = kt_fails, i;
    VtBind(Fs, a);
    ConsPutS("AB\x1b[2;3H\x1b[31mR\x1b[7m\x1b[7mI\x1b[27mN");
    if (a->cells[0].cp != 'A' || a->cells[10].cp != 'R' || a->cells[10].fg != 1 ||
            a->cells[11].bg != 1 || a->cells[12].fg != 1)
        KTFail("terminal cursor/SGR/reverse");
    ConsPutS("\x1b[?1049hALT\x1b[?1049l");
    if (a->cells[0].cp != 'A' || a->cx != 5 || a->cy != 1)
        KTFail("terminal alternate screen restore");
    VtBind(Fs, b);
    ConsPutS("\x1b[2J\x1b[H한Z");
    if (a->cells[0].cp != 'A' || b->cells[0].cp != 0xD55C || b->cells[0].width != 2 ||
            b->cells[1].width || b->cells[2].cp != 'Z')
        KTFail("terminal output isolation/UTF-8");
    VtKeyPush(a, 'a'); VtKeyPush(b, KF_CTRL | 'b');
    if (KeyPop != (KF_CTRL | 'b') || KeyPop) KTFail("terminal input isolation");
    VtBind(Fs, a);
    if (KeyPop != 'a' || KeyPop) KTFail("terminal input queue");
    for (i = 1; i < 256; i++)
        if (!VtKeyPush(a, i)) KTFail("terminal queue capacity");
    if (VtKeyPush(a, 999)) KTFail("terminal queue overflow");
    for (i = 1; i < 256; i++)
        if (KeyPop != i) KTFail("terminal queue order");
    ConsPutS("\x1b[0m\x1b[2J\x1b[Hone\ntwo\nthree\nfour");
    if (a->cells[0].cp != 't' || a->cells[8].cp != 't' || a->cells[16].cp != 'f')
        KTFail("terminal scroll");
    VtResize(a, 5, 2);
    if (a->cells[0].cp != 't' || a->cells[5].cp != 't' || a->cy != 1)
        KTFail("terminal resize preservation");
    VtBind(Fs, old);
    VtRelease(a); VtRelease(b);
    if (kt_fails == f0) Print("  terminals: PASS\n");
}
