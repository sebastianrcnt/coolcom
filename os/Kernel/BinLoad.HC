// In-kernel loader for Cool (Aiwnios) BIN modules, modeled on
// coolc/Host/native.c: copy the file to the heap, apply its patch table
// (exports, absolute addresses, data heaps, imports), sync the I-cache and
// run the module's initializers. Imports resolve against a caller-supplied
// table of kernel routines first, then the module's own exports; an import
// nothing defines gets a stub that reports its name when it is called.
//
// BIN layout: 32-byte header (U64 patch table offset at byte 16), code, patch
// table. Patch entry: U8 type, U32 index, [I32 addend for types 2..12], name.

#define IET_REL_I8           4
#define IET_IMM_I64          11
#define IET_REL32_EXPORT     16
#define IET_REL64_EXPORT     18
#define IET_IMM64_EXPORT     19
#define IET_ABS_ADDR         20
#define IET_CODE_HEAP        21
#define IET_ZEROED_CODE_HEAP 22
#define IET_DATA_HEAP        23
#define IET_ZEROED_DATA_HEAP 24
#define IET_MAIN             25

class CBinSym
{
    U8 *name;
    I64 val;
};

class CBinImport
{
    I64 type, at, addend;
    U8 *name;
};

class CBinMod
{
    U8 *file, *code;
    I64 file_size, code_size;
    CBinSym *syms;
    I64 nsyms, max_syms;
    CBinImport *imps;
    I64 nimps, max_imps;
    I64 *mains;
    I64 nmains, max_mains;
    CBinSym *host;  // kernel routines, searched before the module's exports
    I64 nhost;
};

CBinMod *bin_trap_mod;  // the module whose trap stubs report import names

U8 *BinAlloc(I64 size)
{//Zeroed heap memory for module code and data. The block start is kept
    //16 bytes before the returned pointer, so a Free() of it by module code
    //(the compiler frees what it thinks it allocated) fails the heap check
    //instead of releasing live module memory.
    U8 *p = CAlloc(size + 32);
    if (!p)
        return NULL;
    return p + 16;
}

I64 BinU32(U8 *p)
{
    I64 v = 0;
    MemCpy(&v, p, 4);
    return v;
}

I64 BinI32(U8 *p)
{
    I64 v = BinU32(p);
    if (v & 0x80000000)
        v |= 0xFFFFFFFF00000000;
    return v;
}

I64 BinU64(U8 *p)
{
    I64 v;
    MemCpy(&v, p, 8);
    return v;
}

U8 *BinGrow(U8 *arr, I64 n, I64 *max, I64 size)
{//Room for element n of an array of size-byte elements.
    if (n < *max)
        return arr;
    *max = *max * 2 + 64;
    return ReAlloc(arr, *max * size);
}

U0 BinSymAdd(CBinMod *m, U8 *name, I64 val)
{
    m->syms = BinGrow(m->syms, m->nsyms, &m->max_syms, sizeof(CBinSym));
    m->syms[m->nsyms].name = name;
    m->syms[m->nsyms].val = val;
    m->nsyms++;
}

I64 BinSymFind(CBinMod *m, U8 *name)
{//Kernel routines win over exports, and later exports over earlier ones.
    I64 i;
    for (i = 0; i < m->nhost; i++)
        if (!StrCmp(m->host[i].name, name))
            return m->host[i].val;
    for (i = m->nsyms - 1; i >= 0; i--)
        if (!StrCmp(m->syms[i].name, name))
            return m->syms[i].val;
    return 0;
}

U0 BinTrap(I64 id)
{//Reached through an import stub: nothing defines the import.
    Print("bin: unresolved import %s was called; task halted\n", bin_trap_mod->imps[id].name);
    while (TRUE) {
        Yield;
        ArchWfi;
    }
}

U8 *BinTrapStub(I64 id)
{//movz x0, #id; ldr x17, [pc + 8]; br x17; .quad BinTrap
    U32 *s = MAlloc(24);
    I64 target = &BinTrap;
    s[0] = 0xD2800000 | (id << 5);
    s[1] = 0x58000051;
    s[2] = 0xD61F0220;
    MemCpy(&s[3], &target, 8);
    ArchICacheSync(s, 24);
    return s;
}

Bool BinPatch(CBinMod *m, I64 at, I64 val, I64 width)
{
    if (at < 0 || at + width > m->code_size) {
        Print("bin: patch at %X lies outside the code\n", at);
        return FALSE;
    }
    MemCpy(m->code + at, &val, width);
    return TRUE;
}

Bool BinParse(CBinMod *m, I64 p)
{//Walk the patch table from file offset p.
    U8 *f = m->file, *name, *last = NULL, *heap;
    I64 type, idx, addend, i, at, size;
    while (TRUE) {
        if (p + 1 > m->file_size)
            goto bad;
        type = f[p++];
        if (!type)
            return TRUE;
        if (p + 4 > m->file_size)
            goto bad;
        idx = BinU32(f + p);
        p += 4;
        addend = 0;
        if (type >= 2 && type <= 12) {
            addend = BinI32(f + p);
            p += 4;
        }
        name = f + p;
        while (p < m->file_size && f[p])
            p++;
        if (p++ >= m->file_size)
            goto bad;
        if (type >= IET_REL_I8 && type <= IET_IMM_I64) {
            if (*name)  // an empty name continues the previous import
                last = name;
            if (!last)
                goto bad;
            m->imps = BinGrow(m->imps, m->nimps, &m->max_imps, sizeof(CBinImport));
            m->imps[m->nimps].type = type;
            m->imps[m->nimps].at = idx;
            m->imps[m->nimps].addend = addend;
            m->imps[m->nimps].name = last;
            m->nimps++;
        } else if (type >= IET_REL32_EXPORT && type <= IET_IMM64_EXPORT) {
            if (type == IET_REL32_EXPORT || type == IET_REL64_EXPORT)
                BinSymAdd(m, name, m->code + idx);
            else
                BinSymAdd(m, name, idx);
        } else if (type == IET_ABS_ADDR) {
            for (i = 0; i < idx; i++) {
                at = BinU32(f + p);
                p += 4;
                if (!BinPatch(m, at, BinU64(m->code + at) + m->code, 8))
                    return FALSE;
            }
        } else if (type == IET_CODE_HEAP || type == IET_ZEROED_CODE_HEAP ||
                   type == IET_DATA_HEAP || type == IET_ZEROED_DATA_HEAP) {
            if (type >= IET_DATA_HEAP) {
                size = BinU64(f + p);
                p += 8;
            } else {
                size = BinU32(f + p);
                p += 4;
            }
            if (size < 0 || (type == IET_DATA_HEAP && p + size > m->file_size))
                goto bad;
            heap = BinAlloc(size + 1);
            if (!heap) {
                Print("bin: out of memory for a %d-byte heap\n", size);
                return FALSE;
            }
            if (type == IET_DATA_HEAP) {
                MemCpy(heap, f + p, size);
                p += size;
            }
            if (*name)
                BinSymAdd(m, name, heap);
            for (i = 0; i < idx; i++) {
                if (!BinPatch(m, BinU32(f + p), heap + BinI32(f + p + 4), 8))
                    return FALSE;
                p += 8;
            }
        } else if (type == IET_MAIN) {
            if (idx >= m->code_size)
                goto bad;
            m->mains = BinGrow(m->mains, m->nmains, &m->max_mains, sizeof(I64));
            m->mains[m->nmains++] = idx;
        } else {
            Print("bin: unsupported patch type %d\n", type);
            return FALSE;
        }
    }
bad:
    Print("bin: truncated or invalid patch table at %X\n", p);
    return FALSE;
}

Bool BinResolve(CBinMod *m)
{
    I64 i, val = 0, width, rel, lo, site;
    U8 *last = NULL;
    CBinImport *imp;
    for (i = 0; i < m->nimps; i++) {
        imp = &m->imps[i];
        if (imp->name != last || !val) {
            val = BinSymFind(m, imp->name);
            last = imp->name;
        }
        if (val)
            rel = val;
        else
            rel = BinTrapStub(i);
        rel += imp->addend;
        width = 1 << ((imp->type - IET_REL_I8) >> 1);
        if (!(imp->type & 1)) {  // even types are pc-relative
            site = m->code + imp->at;
            rel -= site + width;
            if (width < 8) {
                lo = -(1 << (width * 8 - 1));
                if (rel < lo || rel > -lo - 1) {
                    Print("bin: relative import %s does not fit\n", imp->name);
                    return FALSE;
                }
            }
        }
        if (!BinPatch(m, imp->at, rel, width))
            return FALSE;
    }
    return TRUE;
}

CBinMod *BinLoad(U8 *bin, I64 size, CBinSym *host, I64 nhost)
{//Load a BIN image; returns NULL on error. Call with x28 set if the module reads Fs.
    CBinMod *m;
    I64 patch, i;
    U0 (*init)();
    if (size < 32)
        return NULL;
    patch = BinU64(bin + 16);
    if (patch < 32 || patch >= size) {
        Print("bin: invalid patch table offset\n");
        return NULL;
    }
    m = CAlloc(sizeof(CBinMod));
    m->file = BinAlloc(size);
    if (!m->file) {
        Print("bin: out of memory for a %d-byte module\n", size);
        return NULL;
    }
    MemCpy(m->file, bin, size);
    m->file_size = size;
    m->code = m->file + 32;
    m->code_size = patch - 32;
    m->host = host;
    m->nhost = nhost;
    bin_trap_mod = m;
    if (!BinParse(m, patch) || !BinResolve(m))
        return NULL;
    ArchICacheSync(m->code, m->code_size);
    for (i = 0; i < m->nmains; i++) {
        init = m->code + m->mains[i];
        (*init)();
    }
    return m;
}
