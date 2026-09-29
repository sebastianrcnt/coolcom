// TempleOS-style shell: every line typed is JIT-compiled by the Cool compiler
// and run at once, and definitions persist from line to line.
//
// The compiler is the checked-in seed coolc/seed/Compiler.BIN, embedded in the
// Image (Blob.S) and loaded by BinLoad with the runtime below in place of what
// coolc/Host/native.c provides on macOS. The shell drives the compiler's
// ExePutS, which calls back ExeCmdLine (the compiler imports it; TempleOS has
// it in the compiler): compile one statement with LexStmt2Bin, run the code,
// repeat. Functions and globals the lines define go into the compiler task's
// hash table, where the next line finds them. JIT code is written into heap
// memory and made executable with ArchICacheSync.
//
// Compiler-built code reads its Fs through x28, which points at shell_tls;
// only the shell task sets x28, so only the shell task may run the compiler.

#define SHELL_STACK    (2 * 1024 * 1024)
#define SHELL_LINE_LEN 512

// Layout facts of the compiler's CCmpCtrl (coolc/Frontend/KernelA.HH).
#define CC_TOKEN      16   // I64 token
#define CC_FLAGS      24   // I64 flags
#define CC_HTC_TABLES 184  // htc.hash_table_lst, define, local, glbl hash tables
#define CCF_EXE_BLK   0x100000
#define CMPF_PRS_SEMICOLON 8
#define INVALID_PTR   I64_MAX
// CHashExport: CHash {next, str, U32 type, use_cnt}, six CHashSrcSym
// pointers, then I64 val.
#define HASH_EXPORT_SIZE   80
#define HASH_STR           8
#define HASH_TYPE          16
#define HASH_EXPORT_VAL    72
#define HTT_EXPORT_SYS_SYM 1

I64 shell_tls[2];         // [0]: the compiler's current task (its Fs)
CBinMod *shell_cmp;
U8 *shell_hash;           // the compiler task's global hash table
U8 *shell_lex_stmt2bin, *shell_exe_puts, *shell_hash_add;
I64 shell_state;          // 0 not started, 1 running, 2 done, -1 failed
I64 shell_check;          // self-test result, see DevTestShell
U8 shell_line[SHELL_LINE_LEN];

// ---- Runtime services the compiler imports (see coolc/Host/native.c) ----

U8 *RtJitAlloc(I64 size)
{//NativeJitAlloc: the heap is identity mapped RWX.
    if (size <= 0)
        size = 1;
    return MAlloc(size);
}

U0 RtJitCommit(U8 *code, U8 *src, I64 size)
{//NativeJitCommit: copy finished code in and make it executable.
    MemCpy(code, src, size);
    ArchICacheSync(code, size);
}

U8 *RtWriteProtectMemCpy(U8 *dst, U8 *src, I64 size)
{
    MemCpy(dst, src, size);
    ArchICacheSync(dst, size);
    return dst;
}

U0 RtFree(U8 *p)
{//The compiler also frees pointers into module data; ignore what isn't a block.
    if (p && HeapOwns(&sys_heap, p))
        Free(p);
}

I64 RtMSize(U8 *p)
{
    if (p && HeapOwns(&sys_heap, p))
        return MSize(p);
    return 0;
}

U8 *RtStrNew(U8 *s)
{
    if (!s)
        s = "";
    return StrNew(s);
}

U8 *RtMAllocIdent(U8 *p)
{
    I64 n = RtMSize(p);
    U8 *q = MAlloc(n);
    if (q && n)
        MemCpy(q, p, n);
    return q;
}

U8 *RtFs() {return shell_tls[0];}
U0 RtSetFs(U8 *task) {shell_tls[0] = task;}

I64 RtBt(U8 *bits, I64 bit)
{
    return (bits[bit >> 3] >> (bit & 7)) & 1;
}

I64 RtBts(U8 *bits, I64 bit)
{
    I64 old = RtBt(bits, bit);
    bits[bit >> 3] |= 1 << (bit & 7);
    return old;
}

I64 RtBtr(U8 *bits, I64 bit)
{
    I64 old = RtBt(bits, bit);
    bits[bit >> 3] &= ~(1 << (bit & 7));
    return old;
}

I64 RtBsf(U64 v)
{
    I64 i;
    for (i = 0; i < 64; i++)
        if ((v >> i) & 1)
            return i;
    return -1;
}

I64 RtBsr(U64 v)
{
    I64 i;
    for (i = 63; i >= 0; i--)
        if ((v >> i) & 1)
            return i;
    return -1;
}

I64 *RtMemSetI64(I64 *dst, I64 val, I64 cnt)
{
    I64 i;
    for (i = 0; i < cnt; i++)
        dst[i] = val;
    return dst;
}

U0 RtSwapI64(I64 *a, I64 *b)
{
    I64 t = *a;
    *a = *b;
    *b = t;
}

F64 RtPow10(F64 e)
{
    F64 r = 1.0, b = 10.0;
    I64 n = e;
    Bool neg = n < 0;
    if (neg)
        n = -n;
    while (n) {
        if (n & 1)
            r *= b;
        b *= b;
        n >>= 1;
    }
    if (neg)
        r = 1.0 / r;
    return r;
}

I64 RtCaller() {return 0;}  // Caller(depth): no frame walk
I64 RtTrue() {return TRUE;}
I64 RtZero() {return 0;}

U0 RtStrPrintFunSeg(U8 *out, I64 addr)
{//StrPrintFunSeg(out, addr, field_len, flags): no symbol lookup yet.
    StrPrint(out, "0x%X", addr);
}

U0 RtPutS(U8 *s)
{
    if (s)
        Print("%s", s);
}

U8 *RtFileNameAbs(U8 *name) {return RtStrNew(name);}

U8 *RtFileRead(U8 *name, I64 *size)
{//No file system yet: #include finds nothing.
    no_warn name;
    if (size)
        *size = 0;
    return NULL;
}

U0 RtExit(I64 status)
{
    Print("shell: compiler exited (%d); shell halted\n", status);
    shell_state = -1;
    while (TRUE) {
        Yield;
        ArchWfi;
    }
}

I64 ShellExeCmdLine(U8 *cc)
{//Compile and run each statement of cc (TempleOS ExeCmdLine); returns the last value.
    I64 res = 0, type, *tok = cc + CC_TOKEN, *flags = cc + CC_FLAGS;
    U8 *code, **h = cc + CC_HTC_TABLES;
    U8 *(*stmt2bin)(U8 *cc, I64 *type, I64 cmp_flags);
    I64 (*fp)();
    if (!shell_hash) {  // CmpCtrlNew points every htc table at Fs->hash_table
        if (!h[0] || h[0] != h[1] || h[1] != h[2] || h[2] != h[3]) {
            Print("shell: unexpected CCmpCtrl layout\n");
            return 0;
        }
        shell_hash = h[3];
    }
    stmt2bin = shell_lex_stmt2bin;
    while (*tok && (*tok != '}' || !(*flags & CCF_EXE_BLK))) {
        code = (*stmt2bin)(cc, &type, CMPF_PRS_SEMICOLON);
        if (code && code != INVALID_PTR) {
            fp = code;
            res = (*fp)();
            // The statement's code is not freed: a global may still point
            // at a string constant stored in it.
        }
    }
    return res;
}

CBinSym shell_rt[64];
I64 shell_nrt;

U0 ShellRt(U8 *name, U8 *addr)
{
    shell_rt[shell_nrt].name = name;
    shell_rt[shell_nrt].val = addr;
    shell_nrt++;
}

U0 ShellRtInit()
{//What the compiler imports, as coolc/Host/native.c registers it.
    shell_nrt = 0;
    ShellRt("NativeJitAlloc", &RtJitAlloc);
    ShellRt("NativeJitCommit", &RtJitCommit);
    ShellRt("MAlloc", &MAlloc);
    ShellRt("CAlloc", &CAlloc);
    ShellRt("Free", &RtFree);
    ShellRt("MSize", &RtMSize);
    ShellRt("StrNew", &RtStrNew);
    ShellRt("MAllocIdent", &RtMAllocIdent);
    ShellRt("Fs", &RtFs);
    ShellRt("SetFs", &RtSetFs);
    ShellRt("Bt", &RtBt);
    ShellRt("Bts", &RtBts);
    ShellRt("Btr", &RtBtr);
    ShellRt("LBts", &RtBts);  // one compiler task: no locking needed
    ShellRt("LBtr", &RtBtr);
    ShellRt("Bsf", &RtBsf);
    ShellRt("Bsr", &RtBsr);
    ShellRt("MemCpy", &MemCpy);
    ShellRt("MemSet", &MemSet);
    ShellRt("MemSetI64", &RtMemSetI64);
    ShellRt("MemCmp", &MemCmp);
    ShellRt("StrLen", &StrLen);
    ShellRt("StrCmp", &StrCmp);
    ShellRt("StrNCmp", &StrNCmp);
    ShellRt("StrCpy", &StrCpy);
    ShellRt("StrICmp", &StrICmp);
    ShellRt("Caller", &RtCaller);
    ShellRt("IsCmdLineMode", &RtTrue);
    ShellRt("StrPrintFunSeg", &RtStrPrintFunSeg);
    ShellRt("PutS", &RtPutS);
    ShellRt("SwapI64", &RtSwapI64);
    ShellRt("Pow10", &RtPow10);
    ShellRt("WriteProtectMemCpy", &RtWriteProtectMemCpy);
    ShellRt("NativeExit", &RtExit);
    ShellRt("AIWNIOS_SetJmp", &ArchSetJmp);
    ShellRt("AIWNIOS_LongJmp", &ArchLongJmp);
    ShellRt("FileNameAbs", &RtFileNameAbs);
    ShellRt("FileRead", &RtFileRead);
    ShellRt("FileWrite", &RtZero);
    ShellRt("ExeCmdLine", &ShellExeCmdLine);
    ShellRt("SysSymImportsResolve", &RtZero);
    ShellRt("FlushMsgs", &RtZero);
    ShellRt("Yield", &Yield);
}

U0 ShellSym(U8 *name, U8 *addr)
{//Make a kernel routine a system symbol; `extern` in ShellA.HH binds it.
    U8 *e = CAlloc(HASH_EXPORT_SIZE), **str = e + HASH_STR;
    U32 *type = e + HASH_TYPE;
    U8 **val = e + HASH_EXPORT_VAL;
    U0 (*add)(U8 *h, U8 *table);
    *str = StrNew(name);
    *type = HTT_EXPORT_SYS_SYM;
    *val = addr;
    add = shell_hash_add;
    (*add)(e, shell_hash);
}

U0 ShellSyms()
{//Every prototype in ShellA.HH needs its symbol here.
    ShellSym("Print", &Print);
    ShellSym("StrPrint", &StrPrint);
    ShellSym("PutChars", &PutChars);
    ShellSym("MAlloc", &MAlloc);
    ShellSym("CAlloc", &CAlloc);
    ShellSym("Free", &Free);
    ShellSym("ReAlloc", &ReAlloc);
    ShellSym("MSize", &MSize);
    ShellSym("StrNew", &StrNew);
    ShellSym("MemSet", &MemSet);
    ShellSym("MemCpy", &MemCpy);
    ShellSym("MemCmp", &MemCmp);
    ShellSym("StrLen", &StrLen);
    ShellSym("StrCpy", &StrCpy);
    ShellSym("StrCat", &StrCat);
    ShellSym("StrCmp", &StrCmp);
    ShellSym("StrNCmp", &StrNCmp);
    ShellSym("StrICmp", &StrICmp);
    ShellSym("ToUpper", &ToUpper);
    ShellSym("ToLower", &ToLower);
    ShellSym("StrFind", &StrFind);
    ShellSym("GetKey", &GetKey);
    ShellSym("GetChar", &GetChar);
    ShellSym("GetStr", &GetStr);
    ShellSym("Yield", &Yield);
    ShellSym("Sleep", &Sleep);
    ShellSym("TaskRep", &TaskRep);
    ShellSym("HeapStats", &HeapStats);
    ShellSym("ConsClear", &ConsClear);
    ShellSym("FbFillRect", &FbFillRect);
    ShellSym("BlkCount", &BlkCount);
    ShellSym("BlkSectors", &BlkSectors);
    ShellSym("BlkRead", &BlkRead);
    ShellSym("BlkWrite", &BlkWrite);
}

I64 ShellExe(U8 *src)
{//JIT-compile and run src; returns the value of its last statement.
    I64 (*exe)(U8 *buf, U8 *filename, I64 flags, U8 *htc);
    ArchX28Set(shell_tls);
    exe = shell_exe_puts;
    return (*exe)(src, NULL, 0, NULL);
}

Bool ShellInit()
{//Load the compiler, then compile the prelude. Runs on the shell task.
    I64 size;
    U8 *bin = ArchCompilerBin(&size);
    ArchX28Set(shell_tls);
    ShellRtInit;
    shell_cmp = BinLoad(bin, size, shell_rt, shell_nrt);
    if (!shell_cmp)
        return FALSE;
    shell_lex_stmt2bin = BinSymFind(shell_cmp, "LexStmt2Bin");
    shell_exe_puts = BinSymFind(shell_cmp, "ExePutS");
    shell_hash_add = BinSymFind(shell_cmp, "HashAdd");
    if (!shell_lex_stmt2bin || !shell_exe_puts || !shell_hash_add) {
        Print("shell: compiler exports missing\n");
        return FALSE;
    }
    ShellExe("");  // ExeCmdLine records the hash table
    if (!shell_hash)
        return FALSE;
    ShellSyms;
    ShellExe(ArchShellPrelude);
    return TRUE;
}

U0 ShellTask(U8 *data)
{//Read, compile and run lines: data of them, or forever if data < 0.
    I64 n = data;
    shell_state = 1;
    if (!ShellInit) {
        Print("shell: compiler failed to load\n");
        shell_state = -1;
        return;
    }
    Print("Cool shell: %d KB compiler loaded\n", shell_cmp->file_size >> 10);
    while (n) {
        Print("> ");
        GetStr(shell_line, SHELL_LINE_LEN);
        ShellExe(shell_line);
        if (n > 0)
            n--;
    }
    if (fdt_test)  // DevTestShell: Sq must have survived from the first line
        shell_check = ShellExe("Sq(7);");
    shell_state = 2;
}

CTask *ShellStart(I64 lines = -1)
{
    return Spawn(&ShellTask, lines, "Shell", 0, SHELL_STACK);
}
