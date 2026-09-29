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

U0 KMain(U8 *heap_start,U8 *heap_end)
{
  MemInit(heap_start,heap_end);
  UartPutS("coolcom kernel\n");
  "heap: %p..%p (%d MB)\n", sys_heap.start, sys_heap.end, (sys_heap.end-sys_heap.start)>>20;
  KTest;
  GicInit;
  CoreInit(0);
  TimerInit;
  ArchIrqOn;
  "timer: %d Hz counter, %d Hz tick\n",cnt_freq,JIFFY_FREQ;
  MPStart(CORES_MAX);
  "%d cores online\n",mp_cnt;
  while (TRUE)
    ArchWfi;
}
