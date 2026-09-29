// GICv2 interrupt controller on the QEMU virt machine.
#define GICD_BASE 0x08000000
#define GICC_BASE 0x08010000

#define GICD_CTLR       0x000
#define GICD_ISENABLER  0x100
#define GICD_IPRIORITYR 0x400
#define GICD_ITARGETSR  0x800

#define GICC_CTLR 0x00
#define GICC_PMR  0x04
#define GICC_IAR  0x0C
#define GICC_EOIR 0x10

#define GIC_IRQS_NUM 256
#define GIC_SPURIOUS 1020

U8 *irq_handlers[GIC_IRQS_NUM]; // U0 (*)(I64 irq); arrays of fun ptrs don't parse
I64 irq_unexpected;

U0 GicInit()
{//Once, on the boot core.
    *(GICD_BASE + GICD_CTLR)(U32 *) = 1;
}

U0 GicCpuInit()
{//On every core: the CPU interface is banked per core.
    *(GICC_BASE + GICC_PMR)(U32 *) = 0xFF;  // let every priority through
    *(GICC_BASE + GICC_CTLR)(U32 *) = 1;
}

U0 IrqSet(I64 irq, U0 (*fp)(I64 irq))
{//Route irq to this core and call fp when it fires.
    //SGIs/PPIs (irq<32) are banked, so call this on each core that wants them.
    irq_handlers[irq] = fp;
    *(GICD_BASE + GICD_IPRIORITYR + irq)(U8 *) = 0x80;
    if (irq >= 32)  // SPIs need a target; SGIs/PPIs are per-core
        *(GICD_BASE + GICD_ITARGETSR + irq)(U8 *) = 1;
    *(GICD_BASE + GICD_ISENABLER + irq / 32 * 4)(U32 *) = 1 << (irq & 31);
}

U0 IrqDispatch()
{
    I64 iar = *(GICC_BASE + GICC_IAR)(U32 *), irq = iar & 0x3FF;
    U0 (*fp)(I64 irq);
    if (irq >= GIC_SPURIOUS)
        return;
    if (irq < GIC_IRQS_NUM && (fp = irq_handlers[irq]))
        (*fp)(irq);
    else
        irq_unexpected++;
    *(GICC_BASE + GICC_EOIR)(U32 *) = iar;
}
