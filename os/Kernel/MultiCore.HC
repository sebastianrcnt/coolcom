// Secondary core bring-up via PSCI.
#define CORES_MAX     4
#define AP_STACK_SIZE (64*1024)
#define PSCI_INVALID_PARAMS (-2)

extern class CTask;

// HolyC classes are packed (no padding): atomics need 8-byte alignment, so keep
// the size a multiple of 8 for arrays of CCPU and I64s ahead of smaller members.
class CCPU
{
    I64 num;
    U8 *stack;
    I64 lock;           // guards this core's task ring
    CTask *seth_task,   // the core's first task, never exits
            *cur_task,
            *dying;       // exited task waiting to be freed
    Bool online;
    U8 pad[7];
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
    GicCpuInit;
}

U0 MPStart(I64 cnt)
{//Start cores 1..cnt-1 and wait for them.
    I64 i, r, t;
    CCPU *c;
    for (i = 1; i < cnt && i < CORES_MAX; i++) {
        c = &cpu_structs[i];
        c->stack = MAlloc(AP_STACK_SIZE);
        r = ArchPsciCpuOn(i, ArchApEntry, c->stack + AP_STACK_SIZE);
        if (r == PSCI_INVALID_PARAMS) {  // no such core
            Free(c->stack);
            break;
        }
        if (r) {
            "Core %d: PSCI CPU_ON failed (%d)\n", i, r;
            goto mp_next;
        }
        t = jiffies + 1000;
        while (!c->online && jiffies < t)
            ArchWfi;
        if (!c->online)
            "Core %d: no response\n", i;
mp_next:
    }
}
