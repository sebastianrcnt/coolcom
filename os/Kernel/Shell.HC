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
// Each shell sets x28 to its own TLS; ArchCtxSwitch saves/restores x28.
// Definitions are private to a shell. Kernel exports are shared.

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

// Private module globals, definitions, TLS and exception contexts per shell.
class CShell
{
    I64 tls[2];
    CBinMod *cmp;
    U8 *hash, *lex_stmt2bin, *exe_puts, *hash_add;
    U8 *stmt_cleanup; // UI cleanup belongs to this shell, even while another runs
    I64 fault_ctx[32], line_ctx[32], fault_daif, line_daif;
    Bool in_stmt, line_active;
    I64 next_slice;
    U8 line[SHELL_LINE_LEN];
};
CShell *ShellCur() {return Fs->shell_ctx;}
#define shell_stmt_cleanup (ShellCur->stmt_cleanup)
CTask *shell_foreground;
I64 shell_state, shell_check; // boot self-test only

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

U8 *RtFs() {return ShellCur->tls[0];}
U0 RtSetFs(U8 *task) {ShellCur->tls[0] = task;}

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
{//StrPrintFunSeg(out, addr, field_len, flags): kernel functions only.
    StrPrintFunSeg(out, addr);
}

U0 RtPutS(U8 *s)
{
    if (s)
        Print("%s", s);
}

// File services for #include and ExeFile, on the FAT32 drives (DskFile.HC).

U8 *RtExtDft(U8 *name, U8 *ext)
{//Give name the extension ext if it has none.
    U8 *res = MAlloc(StrLen(name) + StrLen(ext) + 2);
    StrCpy(res, name);
    if (!FileExtDot(name)) {
        StrCat(res, ".");
        StrCat(res, ext);
    }
    return res;
}

U8 *RtExtChg(U8 *name, U8 *ext)
{//Replace name's extension with ext.
    U8 *res = MAlloc(StrLen(name) + StrLen(ext) + 2);
    StrCpy(res, name);
    FileExtRem(res);
    StrCat(res, ".");
    StrCat(res, ext);
    return res;
}

U8 *RtFileNameAbs(U8 *name, I64 flags = 0)
{
    no_warn flags;
    if (!name)
        name = "";
    if (!DrvCur)
        return StrNew(name);
    return FileNameAbs(name);
}

U8 *RtFileRead(U8 *name, I64 *size, I64 *attr = NULL)
{//NULL if there is no such file; the compiler reports that itself.
    Bool old_silent = Silent;
    U8 *res = NULL;
    if (DrvCur)
        res = FileRead(name, size, attr);
    else if (size)
        *size = 0;
    Silent(old_silent);
    return res;
}

I64 RtFileWrite(U8 *name, U8 *data, I64 size)
{//TRUE if written.
    return FileWrite(name, data, size) > 0 || !size;
}

U0 RtExit(I64 status)
{
    Print("shell: compiler exited (%d); shell halted\n", status);
    if (!VtCurrent || VtCurrent->direct) shell_state = -1;
    while (TRUE) {
        Yield;
        ArchWfi;
    }
}

U0 ShellTrap()
{//bin_trap_hook, throw_hook: an unresolved import was called, or a throw was not
    //caught, on the shell task: back to the prompt.
    if (!ShellCur || !ShellCur->line_active)
        return;
    if (ShellCur->in_stmt) {
        ShellCur->in_stmt = FALSE;
        ArchLongJmp(ShellCur->fault_ctx);
    }
    ArchLongJmp(ShellCur->line_ctx);
}

U0 ShellLineFaultResume()
{
    ArchLongJmp(ShellCur->line_ctx);
}

U0 ShellFaultResume()
{//Where a faulting statement "returns" to: back into ShellExeCmdLine.
    ArchLongJmp(ShellCur->fault_ctx);
}

U0 ShellBreakNow()
{//Ctrl+Alt+C stopped the statement: back to the prompt.
    if (!ShellCur || !ShellCur->in_stmt)
        return;  // the statement already ended
    ShellCur->in_stmt = FALSE;
    Print("\nBreak\n");
    ArchLongJmp(ShellCur->fault_ctx);
}

U0 ShellBreak(CExceptFrame *f)
{//break_hook, at the end of the input IRQ that saw Ctrl+Alt+C. If it interrupted the
    //shell's own statement, resume in ShellBreakNow instead. Otherwise the shell is switched
    //out inside the statement (Sleep, GetKey, or mid-Yield): flag it and wake it, and Yield
    //calls ShellBreakNow when the shell next runs.
    CTask *t = shell_foreground;
    CShell *sh;
    if (vt_focus) t = vt_focus->owner;
    if (!TaskValidate(t)) return;
    sh = t->shell_ctx;
    if (!sh || !sh->in_stmt) return;
    if (Fs == t && f->sp >= t->stk && f->sp <= t->stack_end)
        f->elr = &ShellBreakNow;
    else {
        t->wake_jiffy = 0;
        LBts(&t->task_flags, TASKf_PENDING_BREAK);
    }
}

extern U0 Backtrace(CExceptFrame *f, CTask *task = NULL);  // KDbg.HC

I64 ShellFault(I64 vec, CExceptFrame *f)
{//except_hook: a typed statement faulted; report it and go back to the prompt.
    I64 ec = f->esr >> 26 & 0x3F;
    U8 *what = "exception", where[80];
    if (vec != EXC_CUR_SPX_SYNC || !ShellCur)
        return FALSE;
    if (TaskStackFault(Fs, f) && (ShellCur->in_stmt || ShellCur->line_active)) {
        RawPrint("\nERROR: stack overflow, task %s\n", Fs->task_name);
        // Return on the saved statement stack, never on the exhausted SP.
        if (ShellCur->in_stmt) {
            f->spsr = (f->spsr & ~0x3C0) | ShellCur->fault_daif;
            f->sp = ShellCur->fault_ctx[21];
            f->elr = &ShellFaultResume;
        } else {
            f->spsr = (f->spsr & ~0x3C0) | ShellCur->line_daif;
            f->sp = ShellCur->line_ctx[21];
            f->elr = &ShellLineFaultResume;
        }
        ShellCur->in_stmt = FALSE;
        return TRUE;
    }
    if (!ShellCur->in_stmt)
        return FALSE;
    ShellCur->in_stmt = FALSE;
    if (ec == 0x25 && (f->esr & 0x7F) == 0x4F)
        what = "kernel text write";
    else if (ec == 0x25)
        what = "bad memory access";
    else if (ec == 0x21)
        what = "bad jump";
    else if (ec == 0x22 || ec == 0x26)
        what = "misaligned access";
    else if (ec == 0)
        what = "invalid instruction";
    Print("\nERROR: %s at address %X (code at %s)\n", what, f->far, StrPrintFunSeg(where, f->elr));
    Backtrace(f, Fs);
    f->elr = &ShellFaultResume;
    return TRUE;
}

U8 *ShellFunSeg(U8 *addr, I64 *_offset)
{//fun_seg_hook: the function compiled in the shell holding addr (TempleOS
    //FunSegFind over the hash table: the nearest function start below addr).
    CHashTable *table;
    CHash *h;
    CHashFun *best = NULL;
    I64 i;
    if (!ShellCur)
        return NULL;
    for (table = ShellCur->hash; table; table = table->next)
        for (i = 0; i <= table->mask; i++)
            for (h = table->body[i]; h; h = h->next)
                if (h->type & HTT_FUN && h(CHashFun *)->exe_addr <= addr &&
                        (!best || h(CHashFun *)->exe_addr > best->exe_addr))
                    best = h;
    if (!best || addr - best->exe_addr >= FUN_SEG_MAX)
        return NULL;
    *_offset = addr - best->exe_addr;
    return best->str;
}

I64 ShellExeCmdLine(U8 *cc)
{//Compile and run each statement of cc (TempleOS ExeCmdLine); returns the last value.
    I64 res = 0, type, *tok = cc + CC_TOKEN, *flags = cc + CC_FLAGS;
    U8 *code, **h = cc + CC_HTC_TABLES;
    U8 *(*stmt2bin)(U8 *cc, I64 *type, I64 cmp_flags);
    I64 (*fp)();
    U0 (*cleanup)();
    if (!ShellCur->hash) {  // CmpCtrlNew points every htc table at Fs->hash_table
        if (!h[0] || h[0] != h[1] || h[1] != h[2] || h[2] != h[3]) {
            Print("shell: unexpected CCmpCtrl layout\n");
            return 0;
        }
        ShellCur->hash = h[3];
    }
    stmt2bin = ShellCur->lex_stmt2bin;
    while (*tok && (*tok != '}' || !(*flags & CCF_EXE_BLK))) {
        code = (*stmt2bin)(cc, &type, CMPF_PRS_SEMICOLON);
        if (code && code != INVALID_PTR) {
            fp = code;
            ShellCur->fault_daif = ArchDaif & 0x3C0;
            if (!ArchSetJmp(ShellCur->fault_ctx)) {
                LBtr(&Fs->task_flags, TASKf_PENDING_BREAK);
                ShellCur->in_stmt = TRUE;
                res = (*fp)();
            }
            ShellCur->in_stmt = FALSE;
            cleanup = shell_stmt_cleanup;
            shell_stmt_cleanup = NULL;
            if (cleanup) (*cleanup)();
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
    ShellRt("LBts", &RtBts);  // private compiler state
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
    ShellRt("ExtDft", &RtExtDft);
    ShellRt("ExtChg", &RtExtChg);
    ShellRt("FileNameAbs", &RtFileNameAbs);
    ShellRt("FileRead", &RtFileRead);
    ShellRt("FileWrite", &RtFileWrite);
    ShellRt("ExeCmdLine", &ShellExeCmdLine);
    ShellRt("SysSymImportsResolve", &RtZero);
    ShellRt("FlushMsgs", &RtZero);
    ShellRt("Yield", &Yield);
}

U0 ShellSym(U8 *name, U8 *addr)
{//Make a kernel symbol a system symbol; an `extern` of the prelude binds it.
    U8 *e = CAlloc(HASH_EXPORT_SIZE), **str = e + HASH_STR;
    U32 *type = e + HASH_TYPE;
    U8 **val = e + HASH_EXPORT_VAL;
    U0 (*add)(U8 *h, U8 *table);
    *str = StrNew(name);
    *type = HTT_EXPORT_SYS_SYM;
    *val = addr;
    add = ShellCur->hash_add;
    (*add)(e, ShellCur->hash);
}

U0 ShellSyms()
{//Every kernel symbol (KSym.HC); the prelude's externs bind to them.
    I64 i, n = KSymCnt;
    for (i = 0; i < n; i++)
        ShellSym(KSymName(i), KSymAddr(i));
}

I64 ShellExe(U8 *src)
{//JIT-compile and run src; returns the value of its last statement.
    I64 (*exe)(U8 *buf, U8 *filename, I64 flags, U8 *htc);
    ArchX28Set(ShellCur->tls);
    exe = ShellCur->exe_puts;
    return (*exe)(src, NULL, 0, NULL);
}

Bool ShellInit()
{//Load the compiler, then compile the prelude. Runs on the shell task.
    I64 size;
    U8 *bin = ArchCompilerBin(&size);
    ArchX28Set(ShellCur->tls);
    if (!shell_nrt) ShellRtInit;
    ShellCur->cmp = BinLoad(bin, size, shell_rt, shell_nrt);
    if (!ShellCur->cmp)
        return FALSE;
    ShellCur->lex_stmt2bin = BinSymFind(ShellCur->cmp, "LexStmt2Bin");
    ShellCur->exe_puts = BinSymFind(ShellCur->cmp, "ExePutS");
    ShellCur->hash_add = BinSymFind(ShellCur->cmp, "HashAdd");
    if (!ShellCur->lex_stmt2bin || !ShellCur->exe_puts || !ShellCur->hash_add) {
        Print("shell: compiler exports missing\n");
        return FALSE;
    }
    ShellExe("");  // ExeCmdLine records the hash table
    if (!ShellCur->hash)
        return FALSE;
    ShellSyms;
    ShellExe(ArchShellPrelude);
    return TRUE;
}

U0 ShellTick(CExceptFrame *f)
{//Preempt only JIT statements, never kernel/driver critical sections or the
    //compiler itself. The complete IRQ register frame stays on this task's
    //stack across Yield. Other tasks must run with interrupts enabled.
    CShell *sh = ShellCur;
    if (!sh || !sh->in_stmt || jiffies < sh->next_slice) return;
    if (f->elr < sys_heap.start || f->elr >= sys_heap.end) return;
    sh->next_slice = jiffies + 10;
    ArchIrqOn;
    Yield;
    ArchIrqOff;
}

U0 ShellTask(U8 *data)
{//Read, compile and run lines: data of them, or forever if data < 0.
    I64 n = data, cols = 80, rows = 24;
    Bool primary = !VtCurrent || VtCurrent->direct;
    CVTerm *v;
    if (!VtCurrent) {
        if (fb.base) {cols = fb.cols; rows = fb.rows;}
        v = VtNew(cols, rows); v->direct = TRUE;
        VtBind(Fs, v); VtRelease(v);
        v->owner = Fs;
    }
    if (primary) {shell_state = 1; shell_foreground = Fs;}
    Fs->shell_ctx = CAlloc(sizeof(CShell));
    except_hook = &ShellFault;
    shell_tick_hook = &ShellTick;
    break_hook = &ShellBreak;
    task_break_hook = &ShellBreakNow;
    bin_trap_hook = &ShellTrap;
    throw_hook = &ShellTrap;  // an uncaught throw in a statement (NativeExcept.HC, KHost.HC)
    fun_seg_hook = &ShellFunSeg;
    if (!ShellInit) {
        Print("shell: compiler failed to load\n");
        if (primary) shell_state = -1;
        return;
    }
    Print("Cool shell: %d KB compiler loaded\n", ShellCur->cmp->file_size >> 10);
    if (DrvCur && FileFind("C:/Init.HC")) {
        Print("Running C:/Init.HC\n");
        ShellCur->line_daif = ArchDaif & 0x3C0;
        ShellCur->line_active = TRUE;
        if (!ArchSetJmp(ShellCur->line_ctx))
            ShellExe("#include \"C:/Init.HC\"");
    }
    ShellCur->line_active = FALSE;
    while (n) {
        Print("> ");
        GetLine(ShellCur->line, SHELL_LINE_LEN);
        ShellCur->line_daif = ArchDaif & 0x3C0;
        ShellCur->line_active = TRUE;
        if (!ArchSetJmp(ShellCur->line_ctx))
            ShellExe(ShellCur->line);
        ShellCur->line_active = FALSE;
        if (n > 0)
            n--;
    }
    if (fdt_test && primary)  // DevTestShell: Sq must have survived from the first line
        shell_check = ShellExe("Sq(7);");
    if (primary) shell_state = 2;
}

CTask *ShellStart(I64 lines = -1)
{
    return Spawn(&ShellTask, lines, "Shell", 0, NULL, SHELL_STACK);
}
