// Kernel entry: everything AOT-compiled into the kernel image is included from here.
#include "KernelA.HH"
#include "ArchA.HH"
#include "Fdt.HC"
#include "Uart.HC"
#include "Spin.HC"
#include "StrPrint.HC"
#include "StrA.HC"
#include "Mem.HC"
#include "KTest.HC"
#include "Timer.HC"
#include "Aic.HC"
#include "Except.HC"
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

I64 demo_steps;

U0 DemoTask(U8 *data)
{
    I64 i, n = data;
    F64 x = 1.0;
    for (i = 0; i < 3; i++) {
        x *= 1.5;
        "%s on core %d: step %d x=%f\n", Fs->task_name, Gs->num, i, x;
        ArchAdd(&demo_steps, 1);
        Sleep(100 * n);
    }
}

U0 KMain(U8 *image_end, U8 *dt)
{
    U8 *heap_start, *heap_end;
    if (!FdtInit(dt))
        while (TRUE) {}
    FdtHeap(image_end, dt, &heap_start, &heap_end);
    MemInit(heap_start, heap_end);
    UartPutS("coolcom kernel\n");
    "heap: %p..%p (%d MB)\n", sys_heap.start, sys_heap.end, (sys_heap.end - sys_heap.start) >> 20;
    KTest;
    IntcInit;
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
    if (fdt_test && fdt_vm && fdt_finisher) {
        I64 code = 0, ipi_start = ipi_count;
        if (kt_fails || mp_cnt < 2 || jiffies < 100 || demo_steps < 12)
            code = 1;
        IntcSendIpi(fdt_cpu[1].mpidr);
        I64 deadline = ArchCntVct + ArchCntFrq / 5;
        while (ipi_count == ipi_start && ArchCntVct < deadline)
            ArchWfe;
        if (ipi_count == ipi_start)
            code = 2;
        if (code)
            Print("KERNEL TEST FAIL (%d)\n", code);
        else
            Print("KERNEL TEST PASS\n");
        if (code)
            ArchMmioWrite32(fdt_finisher, (code << 16) | 0x3333);
        else
            ArchMmioWrite32(fdt_finisher, 0x5555);
    }
    while (TRUE) {
        Yield;
        ArchWfi;
    }
}
