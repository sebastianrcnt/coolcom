// PL011 UART on the QEMU virt machine.
#define UART_BASE 0x09000000

U0 UartPut(U8 c)
{
  *(UART_BASE)(U8 *)=c;
}

U0 UartPutS(U8 *s)
{
  while (*s)
    UartPut(*s++);
}
