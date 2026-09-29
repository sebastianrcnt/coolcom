// Tasks and cooperative scheduling, TempleOS style: every core has its own
// ring of tasks and switches only when the running task calls Yield.
#define TASK_STACK_SIZE (128*1024)
#define TASK_NAME_LEN   32

#define TASKf_KILL      1
#define TASKf_SUSPENDED 2

extern class CDrv;

class CTask
{
    CTask *next, *last;  // this core's ring
    U8 *sp;             // saved while switched out
    U8 *stack;          // NULL for a core's first task (runs on the boot stack)
    I64 flags, wake_jiffy, cpu, num, switches;
    U8 task_name[TASK_NAME_LEN];
    CDrv *cur_dv;  // current drive and directory (DskDirB.HC Cd)
    U8 *cur_dir;
};

I64 task_num;

CTask *Fs()
{//The running task.
    return Gs->cur_task;
}

U0 TaskInitCur()
{//Turn what this core is running into its first task: Adam on core 0, Seth on the others.
    CCPU *c = Gs;
    CTask *t = CAlloc(sizeof(CTask));
    t->next = t->last = t;
    t->cpu = c->num;
    t->num = ArchAdd(&task_num, 1);
    if (c->num)
        StrPrint(t->task_name, "Seth%d", c->num);
    else
        StrCpy(t->task_name, "Adam");
    c->seth_task = c->cur_task = t;
}

Bool TaskReady(CTask *t)
{
    if (t->flags & (TASKf_KILL | TASKf_SUSPENDED))
        return FALSE;
    return t->wake_jiffy <= jiffies;
}

U0 TaskReap(CCPU *c)
{//Free a task that exited; can't be done on its own stack.
    CTask *t = c->dying;
    if (t) {
        c->dying = NULL;
        Free(t->stack);
        Free(t->cur_dir);
        Free(t);
    }
}

U0 Yield()
{//Run the next ready task on this core; returns when we are picked again.
    CCPU *c = Gs;
    CTask *cur = c->cur_task, *t;
    I64 daif;
    TaskReap(c);
    while (TRUE) {
        daif = SpinLockIrq(&c->lock);
        t = cur->next;
        while (t != cur && !TaskReady(t))
            t = t->next;
        if (t != cur || TaskReady(cur))
            break;
        SpinUnlockIrq(&c->lock, daif);
        ArchWfi;  // nothing ready: wait for the next tick
    }
    if (t == cur) {
        SpinUnlockIrq(&c->lock, daif);
        return;
    }
    if (cur->flags & TASKf_KILL) {
        cur->last->next = cur->next;
        cur->next->last = cur->last;
        c->dying = cur;
    }
    c->cur_task = t;
    t->switches++;
    SpinUnlockIrq(&c->lock, daif);
    ArchCtxSwitch(&cur->sp, t->sp);
    TaskReap(Gs);
}

U0 Exit()
{//End the running task. Tasks also end by returning from their function.
    CTask *t = Fs;
    if (t == Gs->seth_task) {
        "Exit: %s can't exit\n", t->task_name;
        return;
    }
    t->flags |= TASKf_KILL;
    Yield;
}

U0 Sleep(I64 ms)
{
    CTask *t = Fs;
    t->wake_jiffy = jiffies + ms * JIFFY_FREQ / 1000;
    while (jiffies < t->wake_jiffy)
        Yield;
}

I64 spawn_next_cpu;

CTask *Spawn(U0 (*fp)(U8 *data), U8 *data = NULL, U8 *name = NULL, I64 cpu = -1,
             I64 stack_size = TASK_STACK_SIZE)
{//Start fp(data) as a new task on core cpu (-1: round robin).
    CTask *t = CAlloc(sizeof(CTask));
    CCtxFrame *f;
    CCPU *c;
    I64 daif;
    t->stack = MAlloc(stack_size);
    f = t->stack + (stack_size & ~15) - sizeof(CCtxFrame);
    MemSet(f, 0, sizeof(CCtxFrame));
    f->x19 = fp;
    f->x20 = data;
    f->x30 = ArchTaskStartAddr;
    t->sp = f;
    t->num = ArchAdd(&task_num, 1);
    if (name)
        StrCpy(t->task_name, name);
    else
        StrPrint(t->task_name, "Task%d", t->num);
    if (cpu < 0)
        cpu = ArchAdd(&spawn_next_cpu, 1) % mp_cnt;
    t->cpu = cpu;
    c = &cpu_structs[cpu];
    daif = SpinLockIrq(&c->lock);
    t->next = c->seth_task;  // append at the end of the ring
    t->last = c->seth_task->last;
    t->last->next = t;
    c->seth_task->last = t;
    SpinUnlockIrq(&c->lock, daif);
    return t;
}

U0 TaskRep()
{//List every core's tasks.
    I64 i, daif;
    CCPU *c;
    CTask *t;
    for (i = 0; i < mp_cnt; i++) {
        c = &cpu_structs[i];
        daif = SpinLockIrq(&c->lock);
        t = c->seth_task;
        do {
            "  core %d  #%-3d %-12s switches=%d\n", i, t->num, t->task_name, t->switches;
            t = t->next;
        } while (t != c->seth_task);
        SpinUnlockIrq(&c->lock, daif);
    }
}
