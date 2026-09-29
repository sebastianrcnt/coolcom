// Kernel entry: everything AOT-compiled into the kernel image is included from here.
#include "KernelA.HH"
#include "Uart.HC"

U0 KMain()
{
  UartPutS("hi from HolyC\n");
  while (TRUE) {}
}
