// Apple AICv1 peripheral IRQs; timer and fast IPI arrive as FIQs.
#define AIC_IRQS_NUM 896
U8 *irq_handlers[AIC_IRQS_NUM];
I64 irq_unexpected, ipi_count;

U0 IntcInit() {}
U0 IntcCpuInit()
{
    ArchFiqSourcesInit;
}

U0 IrqSet(I64 irq, U0 (*fp)(I64 irq))
{
    if (irq < 0 || irq >= AIC_IRQS_NUM)
        return;
    irq_handlers[irq] = fp;
    ArchMmioWrite32(fdt_aic + 0x3000 + irq * 4, 0);
    ArchMmioWrite32(fdt_aic + 0x4180 + (irq / 32) * 4, 1 << (irq & 31));
}

U0 IrqDispatch()
{
    I64 event = ArchMmioRead32(fdt_aic + 0x2004);
    I64 irq = event & 0xFFFF;
    U0 (*fp)(I64 irq);
    if ((event >> 16) != 1)
        return;
    if (irq < AIC_IRQS_NUM && (fp = irq_handlers[irq]))
        (*fp)(irq);
    else
        irq_unexpected++;
    ArchMmioWrite32(fdt_aic + 0x4180 + (irq / 32) * 4, 1 << (irq & 31));
}

U0 FiqDispatch()
{
    I64 ipi = ArchIpiStatus;
    if (ipi & 1) {
        ArchIpiAck(1);
        ipi_count++;
    }
    if ((ArchCntvCtl() & 7) == 5)
        TimerFiq;
}

U0 IntcSendIpi(I64 mpidr)
{
    ArchIpiSend((mpidr & 0xff) | (((mpidr >> 8) & 0xff) << 16));
}
