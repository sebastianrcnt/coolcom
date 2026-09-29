// Kernel symbols: the table tools/binlink.py puts in the Image (KSYM_TABLE,
// every HolyC export and assembly symbol, sorted by address). The shell
// registers them all (Shell.HC ShellSyms); KSymFunSeg turns a code address into
// function+offset, as TempleOS FunSeg does, for fault messages.

#define KSYM_CODE 1
#define KSYM_DATA 2
#define KSYM_ASM  3

class CKSym
{
    I64 rel;  // address - table
    U32 name, kind;  // name: offset from the table
};

I64 KSymCnt()
{
    return *ArchKSyms()(I64 *);
}

CKSym *KSymEntry(I64 i)
{
    return ArchKSyms + 8 + i * sizeof(CKSym);
}

U8 *KSymName(I64 i)
{
    return ArchKSyms + KSymEntry(i)->name;
}

U8 *KSymAddr(I64 i)
{
    return ArchKSyms + KSymEntry(i)->rel;
}

U8 *KSymFind(U8 *name)
{//Address of kernel symbol name, NULL if none.
    I64 i, n = KSymCnt;
    for (i = 0; i < n; i++)
        if (!StrCmp(KSymName(i), name))
            return KSymAddr(i);
    return NULL;
}

#define FUN_SEG_MAX 0x10000  // no function is longer; past it an address is nobody's

U8 *KSymFunSeg(U8 *addr, I64 *_offset = NULL)
{//Name of the kernel function holding addr (NULL if none); *_offset from its start.
    I64 lo = 0, hi = KSymCnt - 1, mid, best = -1;
    while (lo <= hi) {  // last symbol at or below addr
        mid = (lo + hi) / 2;
        if (KSymAddr(mid) <= addr) {
            best = mid;
            lo = mid + 1;
        } else
            hi = mid - 1;
    }
    while (best >= 0 && KSymEntry(best)->kind == KSYM_DATA)
        best--;
    if (best < 0 || addr - KSymAddr(best) >= FUN_SEG_MAX)
        return NULL;
    for (mid = best + 1; mid < KSymCnt; mid++)  // a data symbol above ends the code
        if (KSymAddr(mid) > KSymAddr(best)) {
            if (addr >= KSymAddr(mid))
                return NULL;
            break;
        }
    if (_offset)
        *_offset = addr - KSymAddr(best);
    return KSymName(best);
}

U8 *fun_seg_hook;  // U8 *(*)(U8 *addr, I64 *_offset): functions compiled by the shell

U8 *StrPrintFunSeg(U8 *buf, I64 addr, I64 field_len = 0, I64 flags = 0)
{//"Name+0xOFF" for a code address (kernel, or compiled in the shell), else hex.
    I64 off;
    U8 *name = KSymFunSeg(addr, &off);
    U8 *(*hook)(U8 *addr, I64 *_offset);
    no_warn field_len, flags;
    hook = fun_seg_hook;
    if (!name && hook)
        name = (*hook)(addr, &off);
    if (name)
        StrPrint(buf, "%s+0x%X", name, off);
    else
        StrPrint(buf, "0x%X", addr);
    return buf;
}
