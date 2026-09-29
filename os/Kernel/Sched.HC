// Tasks and cooperative scheduling, TempleOS style: every core has its own
// ring of tasks and switches only when the running task calls Yield.
// Tasks are TempleOS CTasks (KernelA.HH): next_task/last_task link this core's
// ring, gs is the core, stk the stack (NULL for a core's first task) and
// context_save_area[0] the stack pointer saved while switched out.
#define TASK_STACK_SIZE (128*1024)

I64 task_num;
CHashTable *adam_hash;  // every task's hash_table (defines, frame pointers)

CTask *Fs()
{//The running task.
    return Gs->cur_task;
}

U0 TaskNew(CTask *t, CCPU *c)
{
    t->addr = t;
    t->task_signature = TASK_SIGNATURE_VAL;
    t->gs = c;
    t->task_num = ArchAdd(&task_num, 1);
    t->hash_table = adam_hash;
    t->rand_seed = t->task_num * 0x9E3779B97F4A7C15;
    QueInit(&t->next_except);
    QueInit(&t->next_cc);
}

U0 TaskInitCur()
{//Turn what this core is running into its first task: Adam on core 0, Seth on the others.
    CCPU *c = Gs;
    CTask *t = CAlloc(sizeof(CTask));
    if (!adam_hash)
        adam_hash = HashTableNew(TASK_HASH_TABLE_SIZE);
    TaskNew(t, c);
    t->next_task = t->last_task = t;
    if (c->num)
        StrPrint(t->task_name, "Seth%d", c->num);
    else {
        StrCpy(t->task_name, "Adam");
        adam_task = t;
    }
    c->seth_task = c->cur_task = t;
}

Bool TaskReady(CTask *t)
{
    if (Bt(&t->task_flags, TASKf_KILL_TASK) || Bt(&t->task_flags, TASKf_SUSPENDED))
        return FALSE;
    return t->wake_jiffy <= jiffies;
}

U0 TaskFree(CTask *t)
{
    t->addr = NULL;
    t->task_signature = 0;
    Free(t->stk);
    Free(t->cur_dir);
    Free(t);
}

U0 TaskReap(CCPU *c)
{//Free a task that exited; can't be done on its own stack.
    CTask *t = c->dying;
    if (t) {
        c->dying = NULL;
        TaskFree(t);
    }
}

U8 *task_break_hook;  // U0 (*)(): runs on a task that returns from Yield with TASKf_PENDING_BREAK set (the shell)

U0 TaskBreakCheck(CTask *t)
{
    U0 (*hook)();
    if (LBtr(&t->task_flags, TASKf_PENDING_BREAK)) {
        hook = task_break_hook;
        if (hook)
            (*hook)();
    }
}

U0 Yield()
{//Run the next ready task on this core; returns when we are picked again.
    CCPU *c = Gs;
    CTask *cur = c->cur_task, *t, *dead;
    I64 daif;
    TaskReap(c);
    while (TRUE) {
        daif = SpinLockIrq(&c->lock);
        t = cur->next_task;
        while (t != cur && !TaskReady(t)) {
            if (Bt(&t->task_flags, TASKf_KILL_TASK) && t != c->seth_task) {
                // Killed while switched out (Kill): it never runs again.
                dead = t;
                t = t->next_task;
                dead->last_task->next_task = t;
                t->last_task = dead->last_task;
                TaskFree(dead);
            } else
                t = t->next_task;
        }
        if (t != cur || TaskReady(cur))
            break;
        SpinUnlockIrq(&c->lock, daif);
        ArchWfi;  // nothing ready: wait for the next tick
    }
    if (t == cur) {
        SpinUnlockIrq(&c->lock, daif);
        TaskBreakCheck(cur);
        return;
    }
    if (Bt(&cur->task_flags, TASKf_KILL_TASK) && cur != c->seth_task) {
        cur->last_task->next_task = cur->next_task;
        cur->next_task->last_task = cur->last_task;
        c->dying = cur;
    }
    c->cur_task = t;
    t->swap_cnter++;
    SpinUnlockIrq(&c->lock, daif);
    ArchCtxSwitch(&cur->context_save_area[0], t->context_save_area[0]);
    TaskReap(Gs);
    TaskBreakCheck(cur);
}

U0 Exit()
{//End the running task. Tasks also end by returning from their function.
    CTask *t = Fs;
    if (t == Gs->seth_task) {
        "Exit: %s can't exit\n", t->task_name;
        return;
    }
    LBts(&t->task_flags, TASKf_KILL_TASK);
    Yield;
}

U0 Sleep(I64 mS)
{//Not for power-saving.  It is to make a program pause without hogging the CPU.
    CTask *t = Fs;
    t->wake_jiffy = jiffies + mS * JIFFY_FREQ / 1000;
    while (jiffies < t->wake_jiffy)
        Yield;
}

U0 SleepUntil(I64 wake_jiffy)
{
    CTask *t = Fs;
    t->wake_jiffy = wake_jiffy;
    while (jiffies < t->wake_jiffy)
        Yield;
}

I64 spawn_next_cpu;

CTask *Spawn(U0 (*fp_start_addr)(U8 *data), U8 *data = NULL, U8 *task_name = NULL, I64 target_cpu = -1,
             CTask *parent = NULL, I64 stk_size = TASK_STACK_SIZE)
{//Start fp_start_addr(data) as a new task on core target_cpu (-1: round robin).
    CTask *t = CAlloc(sizeof(CTask));
    CCtxFrame *f;
    CCPU *c;
    I64 daif;
    if (target_cpu < 0)
        target_cpu = ArchAdd(&spawn_next_cpu, 1) % mp_cnt;
    c = &cpu_structs[target_cpu];
    TaskNew(t, c);
    if (!parent)
        parent = Fs;
    t->parent_task = parent;
    if (parent->cur_dir) {
        t->cur_dv = parent->cur_dv;
        t->cur_dir = StrNew(parent->cur_dir);
    }
    t->stk = MAlloc(stk_size);
    f = t->stk + (stk_size & ~15) - sizeof(CCtxFrame);
    MemSet(f, 0, sizeof(CCtxFrame));
    f->x19 = fp_start_addr;
    f->x20 = data;
    f->x30 = ArchTaskStartAddr;
    t->context_save_area[0] = f;
    if (task_name)
        StrCpy(t->task_name, task_name);
    else
        StrPrint(t->task_name, "Task%d", t->task_num);
    daif = SpinLockIrq(&c->lock);
    t->next_task = c->seth_task;  // append at the end of the ring
    t->last_task = c->seth_task->last_task;
    t->last_task->next_task = t;
    c->seth_task->last_task = t;
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
            "  core %d  #%-3d %-12s %08X switches=%d\n", i, t->task_num, t->task_name, t, t->swap_cnter;
            t = t->next_task;
        } while (t != c->seth_task);
        SpinUnlockIrq(&c->lock, daif);
    }
}

Bool IsSilent()
{//Return StdOut turned-off? (Silent(), KMisc.HC; FALSE before there are tasks.)
    CCPU *c = Gs;
    return c && c->cur_task && Bt(&c->cur_task->display_flags, DISPLAYf_SILENT);
}

// ---- From TempleOS KTask.HC (Aiwnios e155e87) ----

Bool TaskValidate(CTask *task)
{//return TRUE if task looks valid.
    if (!IsValidPtr(task))
        return FALSE;
    if (!task || task->addr != task || task->task_signature != TASK_SIGNATURE_VAL)
        return FALSE;
    else
        return TRUE;
}

Bool Kill(CTask *task, Bool wait = TRUE, Bool just_break = FALSE)
{//Terminate other task. (just_break: stop what it is running, the shell's statement.)
    I64 i;
    if (TaskValidate(task)) {
        if (just_break) {
            LBts(&task->task_flags, TASKf_PENDING_BREAK);
            task->wake_jiffy = 0;
            return TRUE;
        }
        for (i = 0; i < mp_cnt; i++)
            if (task == cpu_structs[i].seth_task)
                return FALSE;
        LBts(&task->task_flags, TASKf_KILL_TASK);
        task->wake_jiffy = 0;
        if (task == Fs)
            Yield;  // doesn't return
        if (wait)
            while (TaskValidate(task))
                Yield;
        return TRUE;
    }
    return FALSE;
}

Bool Suspend(CTask *task = NULL, Bool state = TRUE)
{//Tell scheduler to skip task.
    if (!task)
        task = Fs;
    if (TaskValidate(task)) {
        if (state)
            return LBts(&task->task_flags, TASKf_SUSPENDED);
        else
            return LBtr(&task->task_flags, TASKf_SUSPENDED);
    }
    return FALSE;
}

Bool IsSuspended(CTask *task = NULL)
{
    if (!task)
        task = Fs;
    if (TaskValidate(task))
        return Bt(&task->task_flags, TASKf_SUSPENDED);
    else
        return FALSE;
}
