// PL011 UART on the QEMU virt machine.
#define UART_BASE 0x09000000

U0 UartPut(U8 c)
{
    *(UART_BASE)(U8 *) = c;
}

U0 UartPutS(U8 *s)
{
    while (*s)
        UartPut(*s++);
}

U0 PutChars(U64 ch)
{//Print up to 8 chars packed into ch; target of the 'x'; statement.
    while (ch) {
        UartPut(ch & 0xFF);
        ch >>= 8;
    }
}
