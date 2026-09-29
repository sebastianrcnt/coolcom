// Shutdown and Reboot. Disk writes go straight through the block cache
// (DskCache.HC), so flushing means asking each block device to make them
// durable (BlkFlush). Power control is coolvm's finisher (Fdt.HC): 0x5555
// powers off, 0x7777 resets (coolvm starts again).
// TODO real M1: power off and reset go through the SMC (m1n1 does it with the
// "reboot"/"shutdown" SMC keys); until then these only flush and halt there.

#define FINISHER_POWER_OFF 0x5555
#define FINISHER_RESET     0x7777

U0 DskFlushAll()
{//Make everything written to the disks durable.
    I64 i;
    for (i = 0; i < BlkCount; i++)
        if (BlkFlush(i))
            PrintErr("Flushing disk %d failed\n", i);
}

U0 PowerHalt(I64 finisher_code, U8 *what)
{
    DskFlushAll;
    "%s\n", what;
    if (fdt_finisher)
        ArchMmioWrite32(fdt_finisher, finisher_code);
    else
        "No power control on this machine yet: halted.\n";  // (real M1: SMC, TODO)
    ArchIrqOff;
    while (TRUE)
        ArchWfi;
}

U0 Shutdown()
{//Flush the disks and power off.
    PowerHalt(FINISHER_POWER_OFF, "Power off.");
}

U0 Reboot()
{//Flush the disks and restart.
    PowerHalt(FINISHER_RESET, "Rebooting.");
}
