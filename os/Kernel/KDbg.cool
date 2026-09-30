// Debugging helpers, from TempleOS by Terry A. Davis (public domain) as kept
// in Aiwnios (nrootconauto, commit e155e87): Caller, ChkOnStk, TaskCaller,
// CallerRep (Src/KDbg.HC), D, Dm, Da (Src/KDbg.HC), Uf (Src/ADbg.HC), plain
// text and without the debugger task. The frame chain is AArch64's: x29 points
// at the saved {x29, x30} pair of the caller. Backtraces print with RawPrint
// (no heap), so a fault handler can use them.

#define BACKTRACE_MAX 16

Bool ChkOnStk(U8 *ptr, CTask *task = NULL)
{//Is ptr on task's stack? (A core's first task runs on the boot stack.)
    if (!task)
        task = Fs;
    if (!task->stk)
        return IsValidPtr(ptr);
    return task->stk <= ptr < task->stack_end;
}

U8 *Caller(I64 num = 0)
{//Return address in the caller of the function that calls this (num: further up).
    U8 **fp = ArchFp;  // this function's frame
    I64 i;
    for (i = 0; i <= num; i++) {
        if (!ChkOnStk(fp) || fp >= *fp)
            return NULL;
        fp = *fp;
    }
    if (!ChkOnStk(fp))
        return NULL;
    return fp[1];
}

U8 *TaskCaller(CTask *task = NULL, I64 num = 0)
{//Nth return address on task's stack (0: where it is), for a switched-out task.
    U8 **x29;
    CCtxFrame *f;
    if (!task)
        task = Fs;
    if (task == Fs)
        return Caller(num + 1);
    if (!TaskValidate(task))
        return NULL;
    f = task->context_save_area[0];
    if (!num)
        return f->x30;
    x29 = f->x29;
    while (ChkOnStk(x29, task)) {
        if (!--num)
            return x29[1];
        if (x29 >= *x29)
            break;
        x29 = *x29;
    }
    return NULL;
}

U0 CallerRep(U8 **x29 = NULL, CTask *task = NULL, I64 max = BACKTRACE_MAX)
{//Report the calling routines, from frame x29 up (default: the caller's).
    if (!task)
        task = Fs;
    if (!x29) {
        if (task == Fs)
            x29 = *ArchFp;
        else
            x29 = task->context_save_area[0](CCtxFrame *)->x29;
    }
    while (max-- > 0 && ChkOnStk(x29, task) && x29[1]) {
        RawPrint("  %08X: %P\n", x29[1], x29[1]);
        if (x29 >= *x29)
            break;
        x29 = *x29;
    }
}

U0 Backtrace(CExceptFrame *f, CTask *task = NULL)
{//Where a fault happened and the calls leading there.
    RawPrint("Backtrace:\n  %08X: %P\n", f->elr, f->elr);
    if (f->x[30] && f->x[30] != f->elr && (!ChkOnStk(f->x[29], task) || f->x[29](U8 **)[1] != f->x[30]))
        RawPrint("  %08X: %P (link register)\n", f->x[30], f->x[30]);
    CallerRep(f->x[29], task, BACKTRACE_MAX);
}

U0 D(U8 *addr, I64 cnt = 0x80, Bool show_offset = TRUE)
{//Dump mem, showing offsets.
    I64 i, j, ch;
    U8 *ptr = addr;
    while (cnt > 0) {
        if (show_offset)
            "%08X ", ptr - addr;
        else
            "%010X ", ptr;
        if (cnt > 16)
            j = 16;
        else
            j = cnt;
        for (i = 0; i < j; i++)
            "%02X ", ptr[i];
        for (; i < 16; i++)
            "   ";
        for (i = 0; i < j; i++) {
            ch = ptr[i];
            if (ch < CH_SHIFT_SPACE || ch >= 0x7F)
                ch = '.';
            "%c", ch;
        }
        '\n';
        cnt -= j;
        ptr += j;
    }
}

U0 Dm(U8 *addr, I64 cnt = 0x80)
{//Show mem addr, not offsets.
    D(addr, cnt, FALSE);
}

U0 Da(U8 **addr, I64 cnt = 0x10)
{//Dump mem, showing symbolic addresses.
    while (cnt-- > 0) {
        "%08X:%08X,%P\n", addr, *addr, *addr;
        addr++;
    }
}

U0 Disas(U8 *ptr, I64 len)
{//Disassemble len bytes of code at ptr.
    U8 *end = ptr + len;
    if (!arm64_opcodes_flat)
        LoadOpcodes;
    while (ptr < end)
        ptr = DisasOpc(NULL, ptr);
}

#define UF_MAX 0x1000  // bytes, when nothing marks where a function ends

U8 *KSymNext(U8 *addr)
{//Next kernel symbol above addr (where a kernel function ends).
    I64 i, n = KSymCnt;
    for (i = 0; i < n; i++)
        if (KSymAddr(i) > addr)
            return KSymAddr(i);
    return addr + UF_MAX;
}

U0 Uf(U8 *st)
{//Unassembles a named fun: a kernel one, or one compiled in the shell.
    U8 *start = KSymFind(st), *end, *other;
    CHashFun *tmpf = NULL;
    CDbgInfo *dbg_info;
    CHashTable *table;
    CHash *h;
    I64 i;
    if (start)
        end = KSymNext(start);
    else if (ShellCur && ShellCur->hash && (tmpf = HashFind(st, ShellCur->hash, HTT_FUN)) && (start = tmpf->exe_addr)) {
        if (dbg_info = tmpf->dbg_info)
            end = dbg_info->body[dbg_info->max_line + 1 - dbg_info->min_line];
        else {  // up to the next function compiled after it
            end = start + UF_MAX;
            for (table = ShellCur->hash; table; table = table->next)
                for (i = 0; i <= table->mask; i++)
                    for (h = table->body[i]; h; h = h->next)
                        if (h->type & HTT_FUN && (other = h(CHashFun *)->exe_addr) > start && other < end)
                            end = other;
        }
    } else {
        "Uf: no function %s\n", st;
        return;
    }
    Disas(start, end - start);
    "Code Size:%04X\n", end - start;
}
