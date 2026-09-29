// What the backend needs from its host (the C runtime, in Aiwnios), kept
// private to the backend. The port calls these B-prefixed names instead of
// the host's Fs/HashFind/..., so it behaves the same inside the Aiwnios
// runtime (for differential testing) and inside the CoolC kernel.

#define BHASH_SIZE 64

CBHashTable *BHashTableNew(I64 size)
{//size must be a power of two.
    CBHashTable *t = CAlloc(sizeof(CBHashTable));
    t->mask = size - 1;
    t->body = CAlloc(size * sizeof(CBHash *));
    return t;
}

I64 BHashStr(U8 *s)
{
    I64 h = 0;
    while (*s)
        h = (h << 5) + h + *s++;
    return h;
}

CBHash *BHashFind(U8 *str, CBHashTable *t, I64 type, I64 inst = 1)
{//Like TempleOS HashFind: inst-th match of any of the type bits, searching parent tables too.
    CBHash *h;
    I64 hs = BHashStr(str);
    while (t) {
        h = t->body[hs & t->mask];
        while (h) {
            if ((h->type & type) && !StrCmp(h->str, str)) {
                if (!--inst)
                    return h;
            }
            h = h->next;
        }
        t = t->next;
    }
    return NULL;
}

U0 BHashAdd(CBHash *h, CBHashTable *t)
{
    CBHash **bucket = &t->body[BHashStr(h->str) & t->mask];
    h->next = *bucket;
    *bucket = h;
}

// Queues with the C layout (CBQue is {last,next}; TempleOS CQue is
// {next,last}) and C semantics (QueRem re-inits the entry, QueDel frees the
// head too). Translated from Aiwnios c/cque.c.
U0 BQueInit(CBQue *i)
{
    i->next = i;
    i->last = i;
}

U0 BQueIns(CBQue *a, CBQue *to)
{
    a->next = to->next;
    a->last = to;
    a->last->next = a;
    a->next->last = a;
}

U0 BQueRem(CBQue *a)
{
    CBQue *next = a->next, *last = a->last;
    next->last = last;
    last->next = next;
    BQueInit(a);
}

I64 BQueCnt(CBQue *head)
{
    I64 r = 0;
    CBQue *q;
    for (q = head->next; q != head; q = q->next)
        r++;
    return r;
}

U0 BQueDel(CBQue *f)
{
    CBQue *next = f->next, *next2;
    while (next != f) {
        next2 = next->next;
        Free(next);
        next = next2;
    }
    Free(f);
}

CBHeapCtrl *BHeapCtrlInit(CBHeapCtrl *ct, CBTask *task, I64 is_code_heap)
{//The port allocates with MAlloc/Free; heap controls are only tokens.
    if (!ct)
        ct = CAlloc(sizeof(CBHeapCtrl));
    ct->mem_task = task;
    ct->is_code_heap = is_code_heap;
    return ct;
}

U0 BHeapCtrlDel(CBHeapCtrl *ct)
{//PORT-NOTE: the C heap control frees all its allocations at once; here
    //they are only freed individually, so a compile may leak what C would reclaim.
    Free(ct);
}

I64 BSetWriteNP(I64 n)
{//Apple W^X toggle in the C runtime; code memory is always writable here.
    return n;
}

I64 BDoNothing()
{
    return 0;
}

I64 BFFICall2(U8 *fptr, I64 a, I64 b)
{
    I64 (*fp)(I64 a, I64 b);
    fp = fptr;  // declare and assign separately: an initializer here doesn't parse
    return (*fp)(a, b);
}

// Code buffers. C's OptPassFinal allocates code from an executable heap
// and writes it through MemGetWritePtr (a separate RW alias on OpenBSD). In
// the Aiwnios runtime (BACKEND_HOSTED) code memory is W^X, so code is
// generated into a scratch RW buffer and copied into the executable one by
// BCodeCommit; the pointer maps translate between the two. In the kernel
// all memory is RWX and the maps are the identity.
U8 *b_code_ex, *b_code_wr;
I64 b_code_sz;

#ifdef BACKEND_NATIVE
extern U8 *NativeJitAlloc(I64 size);
extern U0 NativeJitCommit(U8 *dst, U8 *src, I64 size);
#endif

U8 *MemGetWritePtr(U8 *ptr)
{
    if (b_code_wr && b_code_ex <= ptr < b_code_ex + b_code_sz)
        return ptr - b_code_ex + b_code_wr;
    return ptr;
}

U8 *MemGetExecPtr(U8 *ptr)
{
    if (b_code_wr && b_code_wr <= ptr < b_code_wr + b_code_sz)
        return ptr - b_code_wr + b_code_ex;
    return ptr;
}

U8 *BCodeAlloc(I64 size, CBHeapCtrl *heap)
{
#ifdef BACKEND_NATIVE
    // FIX(native): macOS JIT pages execute only after the host commits RW scratch bytes.
    b_code_ex = NativeJitAlloc(size);
    b_code_wr = CAlloc(size);
    b_code_sz = size;
    return b_code_ex;
#else
#ifdef BACKEND_HOSTED
    // __MAlloc, not MAlloc: MAlloc writes caller info into the block header,
    // which faults in write-protected code memory.
    if (heap)  // the host heap control the frontend passed in
        b_code_ex = __MAlloc(size, heap); //HOST
    else
        b_code_ex = __MAlloc(size, Fs->code_heap); //HOST: the Aiwnios task's executable heap
    b_code_wr = CAlloc(size);
    b_code_sz = size;
    return b_code_ex;
#else
    return MAlloc(size);
#endif
#endif
}

U0 BCodeCommit(U8 *obin)
{
#ifdef BACKEND_NATIVE
    // FIX(native): write through the host's MAP_JIT protection transition.
    if (b_code_wr && obin == b_code_ex) {
        NativeJitCommit(b_code_ex, b_code_wr, b_code_sz);
        Free(b_code_wr);
        b_code_wr = NULL;
    }
#else
#ifdef BACKEND_HOSTED
    if (b_code_wr && obin == b_code_ex) {
        WriteProtectMemCpy(b_code_ex, b_code_wr, b_code_sz);
        Free(b_code_wr);
        b_code_wr = NULL;
    }
#endif
#endif
}

I32 BCallPatchCond(U8 *fp, I64 a, I64 b)
{//See CBCodeMiscRef: function-pointer members are stored as U8 *.
    I32 (*f)(I64 a, I64 b);
    f = fp;
    return (*f)(a, b);
}

I32 BCallPatchUncond(U8 *fp, I64 a)
{
    I32 (*f)(I64 a);
    f = fp;
    return (*f)(a);
}

// Numeric conversions as C's (double)x and (int64_t)x. HolyC's postfix
// casts x(F64)/x(I64) reinterpret the bits; only assignment converts.
F64 BToF64(I64 x)
{
    F64 r = x;
    return r;
}

I64 BToI64(F64 x)
{
    I64 r = x;
    return r;
}

U64 BF64ToU64(F64 x)
{//C's (uint64_t)x on AArch64 (fcvtzu): truncates, saturates, NaN->0.
    //HolyC's own F64->integer conversion is signed, so -1.9 would give -1.
    //2^64 and 2^63 are built from their bits: the lexer can't read such literals.
    F64 two64 = 0x43F0000000000000(F64), two63 = 0x43E0000000000000(F64);
    I64 r;
    if (!(x > 0.0))  // negative, zero and NaN
        return 0;
    if (x >= two64)
        return -1;
    if (x >= two63) {
        r = x - two63;
        return r + 0x8000000000000000;
    }
    r = x;
    return r;
}

F64 BFMod(F64 a, F64 b)
{
    return a % b;
}

#ifdef BACKEND_STANDALONE
extern F64 Pow(F64 base, F64 power);  //INTEGRATION: the kernel must provide Pow (libm pow-exact)
#endif

F64 BPow(F64 a, F64 b)
{
    return Pow(a, b);
}

I64 ParseErr(CBCmpCtrl *ctrl, U8 *fmt, ...)
{//The C parser's error report; the frontend normally catches these first.
    Print("backend: error: %s\n", fmt);
    return 0;
}

I64 ParseWarn(CBCmpCtrl *ctrl, U8 *fmt, ...)
{
    Print("backend: warning: %s\n", fmt);
    return 0;
}

CBTask b_task;
CBTask *BFs = &b_task;
b_task.hash_table = BHashTableNew(BHASH_SIZE);
b_task.heap = BHeapCtrlInit(NULL, BFs, FALSE);
b_task.code_heap = BHeapCtrlInit(NULL, BFs, TRUE);
