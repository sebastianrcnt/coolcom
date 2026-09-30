// Top: a full-screen monitor, refreshed about every second. Tasks are listed with their core,
// state, CPU share over the last interval (the core's first task, Adam or SethN, is the idle
// task and gets whatever the others leave), context switches and stack size. Above them: a
// bar per core, the heap (used, free blocks, the largest free one) and the FAT32 drives' free
// space. Keys:  Up Down PgUp PgDn  select   c  sort by CPU   p  by task number   n  by name
//   s  by state   k  kill the selected task (asks)   q  quit
#define TOP_MAX  128
#define TOP_CPU  0
#define TOP_PID  1
#define TOP_NAME 2
#define TOP_STATE 3

CTask *top_t[TOP_MAX];
I64 top_n, top_core[TOP_MAX], top_pid[TOP_MAX], top_dt[TOP_MAX], top_state[TOP_MAX], top_order[TOP_MAX];
I64 top_prev_pid[TOP_MAX], top_prev_ticks[TOP_MAX], top_prev_n, top_prev_at;
I64 top_sort, top_sel, top_first, top_active;
I64 top_core_dt[CORES_MAX], top_core_span[CORES_MAX];
U8 *top_msg;

U0 TopClose()
{
    if (!top_active) return;
    top_active = FALSE;
    AnsiReset;
    AnsiCursorShow;
    AnsiAltScreen(FALSE);
    shell_stmt_cleanup = NULL;
}

I64 TopState(CTask *t, CCPU *c)
{//0 run, 1 ready, 2 sleep, 3 stopped, 4 being killed
    if (Bt(&t->task_flags, TASKf_KILL_TASK)) return 4;
    if (t == c->cur_task) return 0;
    if (Bt(&t->task_flags, TASKf_SUSPENDED)) return 3;
    if (t->wake_jiffy > jiffies) return 2;
    return 1;
}

U8 *TopStateName(I64 s)
{
    if (s == 0) return "RUN";
    if (s == 1) return "READY";
    if (s == 2) return "SLEEP";
    if (s == 3) return "STOP";
    return "KILL";
}

U0 TopSample()
{//Walk every core's ring: tasks, states and the ticks each ran since the last sample.
    I64 i, j, daif, now = ArchCntVct, ticks, prev;
    I64 new_pid[TOP_MAX], new_ticks[TOP_MAX], n = 0;
    CCPU *c;
    CTask *t;
    top_n = 0;
    for (i = 0; i < mp_cnt && i < CORES_MAX; i++) {
        c = &cpu_structs[i];
        top_core_dt[i] = 0;
        daif = SpinLockIrq(&c->lock);
        t = c->seth_task;
        do {
            if (top_n < TOP_MAX) {
                ticks = t->task_ticks;
                if (t == c->cur_task) ticks += now - c->acct_from;  // it is running now
                prev = 0;
                for (j = 0; j < top_prev_n; j++)
                    if (top_prev_pid[j] == t->task_num) prev = top_prev_ticks[j];
                top_t[top_n] = t;
                top_core[top_n] = i;
                top_pid[top_n] = t->task_num;
                top_dt[top_n] = ticks - prev;
                top_state[top_n] = TopState(t, c);
                new_pid[n] = t->task_num;
                new_ticks[n++] = ticks;
                if (t != c->seth_task) top_core_dt[i] += top_dt[top_n];
                top_n++;
            }
            t = t->next_task;
        } while (t != c->seth_task);
        SpinUnlockIrq(&c->lock, daif);
    }
    for (i = 0; i < n; i++) {
        top_prev_pid[i] = new_pid[i];
        top_prev_ticks[i] = new_ticks[i];
    }
    top_prev_n = n;
    for (i = 0; i < mp_cnt && i < CORES_MAX; i++) top_core_span[i] = now - top_prev_at;
    top_prev_at = now;
}

I64 TopBefore(I64 a, I64 b)
{//Does row a sort before row b?
    if (top_sort == TOP_PID) return top_pid[a] < top_pid[b];
    if (top_sort == TOP_NAME) return StrCmp(top_t[a]->task_name, top_t[b]->task_name) < 0;
    if (top_sort == TOP_STATE) {
        if (top_state[a] != top_state[b]) return top_state[a] < top_state[b];
        return top_pid[a] < top_pid[b];
    }
    if (top_t[a] == cpu_structs[top_core[a]].seth_task) return FALSE;  // idle tasks last
    if (top_t[b] == cpu_structs[top_core[b]].seth_task) return TRUE;
    if (top_dt[a] != top_dt[b]) return top_dt[a] > top_dt[b];
    return top_pid[a] < top_pid[b];
}

U0 TopSort()
{
    I64 i, j, k;
    for (i = 0; i < top_n; i++) top_order[i] = i;
    for (i = 1; i < top_n; i++) {
        k = top_order[i];
        for (j = i - 1; j >= 0 && TopBefore(k, top_order[j]); j--) top_order[j + 1] = top_order[j];
        top_order[j + 1] = k;
    }
}

I64 TopPercent(I64 dt, I64 span)
{//Tenths of a percent.
    if (span <= 0) return 0;
    return dt * 1000 / span;
}

U8 *TopSortName()
{
    if (top_sort == TOP_PID) return "task";
    if (top_sort == TOP_NAME) return "name";
    if (top_sort == TOP_STATE) return "state";
    return "cpu";
}

U0 TopBar(I64 tenths, I64 width)
{
    I64 i, filled = tenths * width / 1000;
    if (filled > width) filled = width;
    ConsPut('[');
    AnsiFg(ANSI_GREEN);
    for (i = 0; i < filled; i++) ConsPut('|');
    AnsiFg(ANSI_GRAY);
    for (; i < width; i++) ConsPut('.');
    AnsiReset;
    ConsPut(']');
}

U0 TopMB(I64 bytes)
{//Print with one decimal in KB, MB or GB.
    if (bytes >= (1 << 30)) Print("%d.%d GB", bytes >> 30, ((bytes & 0x3FFFFFFF) * 10) >> 30);
    else if (bytes >= (1 << 20)) Print("%d.%d MB", bytes >> 20, ((bytes & 0xFFFFF) * 10) >> 20);
    else Print("%d KB", bytes >> 10);
}

I64 TopFreeClus(CDrv *dv)
{//FSInfo's free cluster count; -1 if the volume does not keep one.
    if (dv->fis->free_clus == 0xFFFFFFFF) return -1;
    return dv->fis->free_clus;
}

U0 TopDrives(I64 y)
{//One line per FAT32 drive: free and total bytes.
    I64 i, total, free, csz;
    CDrv *dv;
    for (i = 0; i < DRVS_NUM; i++) {
        dv = blkdev.let_to_drv[i];
        if (!dv || dv->dv_signature != DRV_SIGNATURE_VAL) goto next_drv;
        csz = dv->spc * BLK_SIZE;
        total = ((dv->size + dv->drv_offset - dv->data_area) / dv->spc - 1) * csz;
        free = TopFreeClus(dv);
        AnsiCursor(y++, 1);
        AnsiClearEol;
        Print("Disk %c: FAT32  ", Drv2Let(dv));
        if (free < 0) Print("free ?");
        else {Print("free "); TopMB(free * csz);}
        Print(" of "); TopMB(total);
next_drv:
    }
}

U0 TopDraw(I64 rows, I64 cols)
{
    I64 i, r, k, y, pct, sec = jiffies / JIFFY_FREQ, nu, nf, big, first_task_row = 8;
    CTask *t;
    U8 line[256];
    AnsiCursor(1, 1);
    AnsiSet(ANSI_BLACK, ANSI_WHITE);
    AnsiClearEol;
    Print(" Top   up %02d:%02d:%02d   %d tasks on %d cores   sort: %s", sec / 3600, (sec / 60) % 60, sec % 60, top_n, mp_cnt,
            TopSortName);
    AnsiReset;
    for (i = 0; i < mp_cnt && i < CORES_MAX; i++) {
        AnsiCursor(2 + i, 1);
        AnsiClearEol;
        // busy share: what the tasks other than the idle one ran
        pct = TopPercent(top_core_dt[i], top_core_span[i]);
        Print("Core %d ", i);
        TopBar(pct, 30);
        Print(" %3d.%d%%", pct / 10, pct % 10);
    }
    y = 2 + mp_cnt;
    HeapCheck(&sys_heap, &nu, &nf, &big);
    AnsiCursor(y, 1);
    AnsiClearEol;
    Print("Heap  ");
    TopBar(sys_heap.used * 1000 / sys_heap.total, 30);
    Print(" ");
    TopMB(sys_heap.used);
    Print(" of ");
    TopMB(sys_heap.total);
    y++;
    AnsiCursor(y, 1);
    AnsiClearEol;
    Print("      %d blocks in use, %d free (largest ", nu, nf);
    TopMB(big);
    Print(")");
    y++;
    TopDrives(y);
    y = 2 + mp_cnt + 3 + 1;
    first_task_row = y + 1;
    AnsiCursor(y, 1);
    AnsiSet(ANSI_BLACK, ANSI_WHITE);
    AnsiClearEol;
    Print("  TASK CORE STATE     CPU%%  SWITCHES  STACK  NAME");
    AnsiReset;
    r = rows - first_task_row;  // task rows on screen
    if (r < 1) r = 1;
    if (top_sel >= top_n) top_sel = top_n - 1;
    if (top_sel < 0) top_sel = 0;
    if (top_sel < top_first) top_first = top_sel;
    if (top_sel >= top_first + r) top_first = top_sel - r + 1;
    for (i = 0; i < r; i++) {
        AnsiCursor(first_task_row + i, 1);
        AnsiClearEol;
        if (top_first + i < top_n) {
            k = top_order[top_first + i];
            t = top_t[k];
            pct = TopPercent(top_dt[k], top_core_span[top_core[k]]);
            StrPrint(line, "%6d %4d %-7s %3d.%d %9d %5dK  %s", top_pid[k], top_core[k], TopStateName(top_state[k]),
                     pct / 10, pct % 10, t->swap_cnter, (t->stack_end - t->stk) >> 10, t->task_name);
            if (t == cpu_structs[top_core[k]].seth_task) StrCat(line, " (idle)");
            if (top_first + i == top_sel) AnsiReverse;
            TextPutLine(line, StrLen(line), cols);
            if (top_first + i == top_sel) AnsiReset;
        }
    }
    AnsiCursor(rows, 1);
    AnsiSet(ANSI_BLACK, ANSI_WHITE);
    AnsiClearEol;
    if (top_msg) Print("%s", top_msg);
    else Print(" q quit  k kill  c cpu  p task  n name  s state  arrows select");
    AnsiReset;
}

U0 Top()
{
    I64 rows, cols, ev, c, deadline, k;
    if (top_active) {Print("Top is already running\n"); return;}
    top_active = TRUE;
    top_msg = NULL;
    top_sort = TOP_CPU;
    top_sel = top_first = top_prev_n = 0;
    top_prev_at = ArchCntVct;
    shell_stmt_cleanup = &TopClose;
    AnsiAltScreen(TRUE);
    AnsiCursorHide;
    AnsiClear;
    TopSample;  // a first sample gives the baseline; the next one, a second later, the shares
    Sleep(200);
    while (TRUE) {
        AnsiTermSize(&rows, &cols);
        TopSample;
        TopSort;
        TopDraw(rows, cols);
        top_msg = NULL;
        deadline = jiffies + JIFFY_FREQ;
        while (jiffies < deadline && !KeyPending) Sleep(20);
        if (!KeyPending) goto top_again;
        ev = GetKey;
        c = ev & KEY_CODE;
        if (c == 'q' || c == 'Q' || c == KEY_ESC) break;
        else if (c == KEY_UP) top_sel--;
        else if (c == KEY_DOWN) top_sel++;
        else if (c == KEY_PGUP) top_sel -= 10;
        else if (c == KEY_PGDN) top_sel += 10;
        else if (c == KEY_HOME) top_sel = 0;
        else if (c == KEY_END) top_sel = top_n - 1;
        else if (c == 'c') top_sort = TOP_CPU;
        else if (c == 'p') top_sort = TOP_PID;
        else if (c == 'n') top_sort = TOP_NAME;
        else if (c == 's') top_sort = TOP_STATE;
        else if (c == 'k' && top_sel < top_n) {
            k = top_order[top_sel];
            if (top_t[k] == Fs || top_t[k] == cpu_structs[top_core[k]].seth_task)
                top_msg = " Cannot kill the idle task or Top's own task";
            else {
                AnsiCursor(rows, 1);
                AnsiSet(ANSI_BLACK, ANSI_YELLOW);
                AnsiClearEol;
                Print(" Kill task %d %s? (y/n)", top_pid[k], top_t[k]->task_name);
                AnsiReset;
                if ((GetKey & KEY_CODE) == 'y') {
                    Kill(top_t[k], FALSE);
                    top_msg = " Kill requested";
                }
            }
        }
        if (top_sel < 0) top_sel = 0;
top_again:
    }
    TopClose;
}
