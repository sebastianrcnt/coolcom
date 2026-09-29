// Apple S5L UART, driven through simple 32-bit MMIO accessors.
U0 UartPut(U8 c)
{
    while (!(ArchMmioRead32(fdt_uart + 0x10) & 2)) {}
    ArchMmioWrite32(fdt_uart + 0x20, c);
}

I64 UartGet()
{//A received byte, or -1 if none (UTRSTAT.RXD, then URXH).
    if (!(ArchMmioRead32(fdt_uart + 0x10) & 1))
        return -1;
    return ArchMmioRead32(fdt_uart + 0x24) & 0xFF;
}

U0 UartPutS(U8 *s)
{
    while (*s)
        UartPut(*s++);
}
