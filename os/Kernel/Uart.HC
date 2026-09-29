// Apple S5L UART, driven through simple 32-bit MMIO accessors.
U0 UartPut(U8 c)
{
    while (!(ArchMmioRead32(fdt_uart + 0x10) & 2)) {}
    ArchMmioWrite32(fdt_uart + 0x20, c);
}

U0 UartPutS(U8 *s)
{
    while (*s)
        UartPut(*s++);
}

U0 PutChars(U64 ch)
{
    while (ch) {
        UartPut(ch & 0xFF);
        ch >>= 8;
    }
}
