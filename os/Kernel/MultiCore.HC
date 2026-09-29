// Secondary cores are released through m1n1 spin-table words.
#define CORES_MAX     8

// HolyC classes are packed (no padding): atomics need 8-byte alignment, so keep
// the size a multiple of 8 for arrays of CCPU and I64s ahead of smaller members.
class CCPU
{
    I64 num;
    I64 lock;           // guards this core's task ring
    CTask *seth_task,   // the core's first task, never exits
            *cur_task,
            *dying;       // exited task waiting to be freed
    Bool online;        // (Bool is a U64)
};

CCPU cpu_structs[CORES_MAX];
I64 mp_cnt = 1;  // cores online

CCPU *Gs()
{//This core's CCPU.
    return ArchTpidr;
}

U0 CoreInit(I64 num)
{//Common per-core init, runs on the core itself.
    CCPU *c = &cpu_structs[num];
    c->num = num;
    ArchTpidrSet(c);
    IntcCpuInit;
}

U0 MPStart(I64 cnt)
{
    I64 i, t;
    CCPU *c;
    for (i = 1; i < cnt && i < fdt_ncpu && i < CORES_MAX; i++) {
        if (!fdt_cpu[i].release)
            goto mp_next;
        c = &cpu_structs[i];
        ArchSpinRelease(fdt_cpu[i].release, ArchApEntry);
        t = ArchCntVct + ArchCntFrq;
        while (!c->online && ArchCntVct < t)
            ArchWfe;
        if (!c->online)
            "Core %d: no response\n", i;
mp_next:
    }
}
