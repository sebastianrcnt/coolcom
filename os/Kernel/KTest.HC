// Boot-time self-tests for the heap and the mem/string library.

I64 kt_fails, kt_seed = 0x2545F4914F6CDD1D;

U0 KTFail(U8 *what)
{
    Print("  FAIL: %s\n", what);
    kt_fails++;
}

// xorshift64
I64 KTRand()
{
    U64 x = kt_seed;
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    kt_seed = x;
    return x & I64_MAX;
}

U0 KTFill(U8 *p, I64 n, I64 seed)
{
    I64 i;
    for (i = 0; i < n; i++)
        p[i] = seed + i * 7;
}

Bool KTVerify(U8 *p, I64 n, I64 seed)
{
    I64 i;
    for (i = 0; i < n; i++)
        if (p[i] != (seed + i * 7) & 0xFF)
            return FALSE;
    return TRUE;
}

U0 KTestStr()
{
    U8 buf[32], *s;
    I64 f0 = kt_fails;
    if (StrLen("hello") != 5 || StrLen("") != 0)
        KTFail("StrLen");
    StrCpy(buf, "abc");
    StrCat(buf, "def");
    if (StrCmp(buf, "abcdef") || StrLen(buf) != 6)
        KTFail("StrCpy/StrCat");
    if (StrCmp("abc", "abd") >= 0 || StrCmp("b", "a") <= 0 || StrCmp("a", "a"))
        KTFail("StrCmp");
    if (StrNCmp("abcx", "abcy", 3) || StrNCmp("abcx", "abcy", 4) >= 0)
        KTFail("StrNCmp");
    if (StrICmp("HeLLo", "hello") || StrICmp("a", "B") >= 0)
        KTFail("StrICmp");
    if (StrOcc("banana", 'a') != 3 || StrOcc("x", 'y'))
        KTFail("StrOcc");
    s = "banana";
    if (StrFind("nan", s) != s + 2 || StrFind("xyz", s))
        KTFail("StrFind");
    if (ToUpper('q') != 'Q' || ToUpper('Q') != 'Q' || ToLower('Q') != 'q' || ToUpper('1') != '1')
        KTFail("ToUpper/ToLower");
    MemSet(buf, 'z', 11);
    if (buf[0] != 'z' || buf[10] != 'z')
        KTFail("MemSet");
    StrCpy(buf, "0123456789");
    MemCpy(buf + 2, buf, 8);   // overlapping, forward
    if (MemCmp(buf, "0101234567", 10))
        KTFail("MemCpy overlap up");
    StrCpy(buf, "0123456789");
    MemCpy(buf, buf + 2, 8);   // overlapping, backward
    if (MemCmp(buf, "2345678989", 10))
        KTFail("MemCpy overlap down");
    if (MemCmp("abc", "abd", 3) >= 0 || MemCmp("abc", "abd", 2))
        KTFail("MemCmp");
    s = StrNew("heap str");
    if (!s || StrCmp(s, "heap str"))
        KTFail("StrNew");
    Free(s);
    if (kt_fails == f0)
        Print("  strings/mem: PASS\n");
}

#define KT_SLOTS 400

U0 KTestHeap()
{
    U8 *ptr[KT_SLOTS], *p, *q;
    I64 sz[KT_SLOTS], sd[KT_SLOTS];
    I64 i, j, n, r, last, f0 = kt_fails, free0 = HeapFreeBytes(&sys_heap), nf, errs0 = heap_errs;

    for (i = 0; i < KT_SLOTS; i++)
        ptr[i] = NULL;

    // 1. random alloc/free with pattern verification
    for (n = 0; n < 60000; n++) {
        i = KTRand() % KT_SLOTS;
        if (ptr[i]) {
            if (!KTVerify(ptr[i], sz[i], sd[i])) {
                KTFail("pattern corrupted");
                return;
            }
            Free(ptr[i]);
            ptr[i] = NULL;
        } else {
            r = KTRand() % 100;
            if (r < 70)
                sz[i] = KTRand() % 300;
            else if (r < 97)
                sz[i] = KTRand() % 6000;
            else
                sz[i] = KTRand() % 200000;
            sd[i] = KTRand();
            ptr[i] = MAlloc(sz[i]);
            if (!ptr[i]) {
                KTFail("alloc returned NULL");
                return;
            }
            if (ptr[i](I64) & 15 || MSize(ptr[i]) < sz[i])
                KTFail("alignment/MSize");
            KTFill(ptr[i], sz[i], sd[i]);
        }
        if (n % 15000 == 0 && !HeapCheck(&sys_heap)) {
            KTFail("heap inconsistent");
            return;
        }
    }
    for (i = 0; i < KT_SLOTS; i++)
        if (ptr[i]) {
            if (!KTVerify(ptr[i], sz[i], sd[i]))
                KTFail("pattern corrupted (final)");
            Free(ptr[i]);
            ptr[i] = NULL;
        }
    HeapCheck(&sys_heap, NULL, &nf);
    if (nf != 1 || HeapFreeBytes(&sys_heap) != free0)
        KTFail("random cycle leaked/fragmented");
    else
        Print("  random alloc/free: PASS\n");

    // 2. CAlloc zeroing, alignment of all small sizes
    j = kt_fails;
    for (i = 0; i < 300; i++) {
        p = MAlloc(i);   // dirty it, free, then CAlloc must still be zero
        MemSet(p, 0xFF, i);
        Free(p);
        p = CAlloc(i);
        if (p(I64) & 15 || !KTVerify(p, 0, 0))
            KTFail("CAlloc align");
        for (n = 0; n < i; n++)
            if (p[n])
                KTFail("CAlloc not zero");
        Free(p);
    }
    if (kt_fails == j)
        Print("  CAlloc: PASS\n");

    // 3. ReAlloc growth/shrink preserving contents
    j = kt_fails;
    p = MAlloc(8);
    KTFill(p, 8, 5);
    for (n = 8; n < 3000000; n = n * 2 + 3) {
        last = n;
        q = MAlloc(64);   // an obstacle so growth can't always be in place
        p = ReAlloc(p, n);
        if (!p || !KTVerify(p, 8, 5)) {
            KTFail("ReAlloc grow");
            return;
        }
        KTFill(p, n, 5);
        Free(q);
    }
    for (n = last; n > 8; n = (n - 3) / 2) {
        p = ReAlloc(p, n);
        if (!p || !KTVerify(p, n, 5)) {
            KTFail("ReAlloc shrink");
            return;
        }
    }
    p = ReAlloc(p, 40);
    if (!KTVerify(p, 8, 5))
        KTFail("ReAlloc final");
    q = MAllocIdent(p);
    if (!q || MSize(q) != MSize(p) || MemCmp(p, q, 40))
        KTFail("MAllocIdent");
    Free(q);
    Free(p);
    q = ReAlloc(NULL, 100);
    if (!q)
        KTFail("ReAlloc(NULL)");
    Free(q);
    if (kt_fails == j)
        Print("  ReAlloc/MAllocIdent: PASS\n");

    // 4. big allocations
    j = kt_fails;
    p = MAlloc(100 << 20);
    if (!p)
        KTFail("100MB alloc");
    else {
        MemSet(p, 0xA5, 100 << 20);
        for (i = 0; i < (100 << 20); i += 4096 + 8)
            if (p[i] != 0xA5)
                KTFail("100MB content");
        q = MAlloc(300 << 20);
        if (!q)
            KTFail("300MB alloc");
        Free(p);
        Free(q);
    }
    if (MAlloc(2 << 30))
        KTFail("2GB alloc should fail");
    p = MAlloc(free0 - 4096);   // nearly everything
    if (!p)
        KTFail("near-full alloc");
    else {
        if (MAlloc(1 << 20))
            KTFail("alloc past full should fail");
        Free(p);
    }
    if (kt_fails == j)
        Print("  big allocs: PASS\n");

    // 5. misuse detection
    j = kt_fails;
    p = MAlloc(50);
    Free(p);
    Free(p);            // double free -> reported, ignored
    Free(p + 8);        // interior pointer
    Free(NULL);         // ok
    if (heap_errs - errs0 != 2)
        KTFail("misuse not detected");
    // Exact (including unaligned) boundaries, rejected free/realloc and walks.
    p = MAlloc(13);
    p[13] ^= 1;
    Free(p);
    if (ReAlloc(p, 30) || HeapCheck(&sys_heap) || heap_errs != errs0 + 5)
        KTFail("tail canary detection");
    p[13] ^= 1;
    p[-1] ^= 1;
    Free(p);
    if (heap_errs != errs0 + 6)
        KTFail("front canary detection");
    p[-1] ^= 1;
    Free(p);
    heap_errs = errs0;
    if (kt_fails == j)
        Print("  misuse detection: PASS\n");
}

U0 KTest()
{
    I64 nf, free0 = HeapFreeBytes(&sys_heap);
    Print("kernel self-test:\n");
    KTestStr();
    KTestHeap();
    HeapCheck(&sys_heap, NULL, &nf);
    if (nf != 1 || HeapFreeBytes(&sys_heap) != free0 || heap_errs)
        KTFail("heap not back to initial state");
    HeapStats();
    if (kt_fails)
        Print("SELFTEST FAIL (%d)\n", kt_fails);
    else
        Print("SELFTEST PASS\n");
}
