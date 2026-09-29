// Kernel entry: everything AOT-compiled into the kernel image is included from here.
#include "KernelA.HH"
#include "ArchA.HH"
#include "Uart.HC"
#include "Spin.HC"
#include "StrPrint.HC"
#include "StrA.HC"
#include "Mem.HC"
#include "KTest.HC"
#include "Gic.HC"
#include "Except.HC"
#include "Timer.HC"
#include "MultiCore.HC"
#include "Sched.HC"

U0 KMainAP(I64 num)
{//Secondary cores start here (from Boot.S).
    CoreInit(num);
    TaskInitCur;
    TimerCoreInit;
    ArchIrqOn;
    cpu_structs[num].online = TRUE;
    ArchAdd(&mp_cnt, 1);
    while (TRUE) {
        Yield;
        ArchWfi;
    }
}

U0 DemoTask(U8 *data)
{
    I64 i, n = data;
    F64 x = 1.0;
    for (i = 0; i < 3; i++) {
        x *= 1.5;
        "%s on core %d: step %d x=%f\n", Fs->task_name, Gs->num, i, x;
        Sleep(100 * n);
    }
}

U0 KMain(U8 *heap_start, U8 *heap_end)
{
    MemInit(heap_start, heap_end);
    UartPutS("coolcom kernel\n");
    "heap: %p..%p (%d MB)\n", sys_heap.start, sys_heap.end, (sys_heap.end - sys_heap.start) >> 20;
    KTest;
    GicInit;
    CoreInit(0);
    TaskInitCur;
    TimerInit;
    ArchIrqOn;
    "timer: %d Hz counter, %d Hz tick\n", cnt_freq, JIFFY_FREQ;
    MPStart(CORES_MAX);
    "%d cores online\n", mp_cnt;
    I64 i;
    for (i = 1; i <= 4; i++)
        Spawn(&DemoTask, i);
    TaskRep;
    Sleep(1500);
    "after demo:\n";
    TaskRep;
    "heap used: %d bytes\n", HeapUsedBytes(&sys_heap);
    while (TRUE) {
        Yield;
        ArchWfi;
    }
}
