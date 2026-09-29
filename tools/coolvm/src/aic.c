/*
 * Apple Interrupt Controller, v1 (compatible "apple,t8103-aic", "apple,aic").
 *
 * Register map: linux drivers/irqchip/irq-apple-aic.c (AIC_* defines and the
 * offsets computed in aic_of_ic_init() for version 1) and m1n1 src/aic_regs.h:
 *   0x0004 INFO        [15:0] NR_IRQ   (t8103: 896; reads 0x000a0380 on real hardware)
 *   0x0010 CONFIG
 *   0x2000 WHOAMI      index of the reading CPU (Linux WARNs if != cpu id)
 *   0x2004 EVENT       read = ack: type<<16 | num, 0 if none; auto-masks the IRQ
 *   0x2008 IPI_SEND    bit n: OTHER IPI to cpu n, bit 31: SELF IPI (non-fast-IPI path)
 *   0x200c IPI_ACK     bit0 OTHER, bit31 SELF
 *   0x2024 IPI_MASK_SET / 0x2028 IPI_MASK_CLR
 *   0x3000 TARGET_CPU[irq] (4 bytes each, cpu bitmask)
 *   0x4000 SW_SET  0x4080 SW_CLR  0x4100 MASK_SET  0x4180 MASK_CLR  0x4200 HW_STATE
 *          (each 32 words = 1024 irq bits; NR_IRQ used = 896)
 *   0x5008 + cpu<<7 IPI_SET(cpu)  0x500c CLR  0x5024 MASK_SET  0x5028 MASK_CLR
 *
 * Also the Apple fast-IPI system registers (IPI_RR_LOCAL/GLOBAL, IPI_SR) are
 * modelled here, since on t8103 Linux uses them instead of the MMIO IPIs
 * (aic1_local_fipi_info).
 *
 * Deviation: only one die; IRQ delivery to a CPU is "IRQ line asserted when any
 * unmasked pending IRQ targets it" instead of the hardware's exact arbitration.
 * The IRQ line is delivered to the vCPU as a virtual IRQ (HV_INTERRUPT_TYPE_IRQ);
 * timer and fast-IPI FIQs as HV_INTERRUPT_TYPE_FIQ.
 */
#include "coolvm.h"

#define AIC_INFO 0x0004
#define AIC_CONFIG 0x0010
#define AIC_WHOAMI 0x2000
#define AIC_EVENT 0x2004
#define AIC_IPI_SEND 0x2008
#define AIC_IPI_ACK 0x200c
#define AIC_IPI_MASK_SET 0x2024
#define AIC_IPI_MASK_CLR 0x2028
#define AIC_TARGET_CPU 0x3000
#define AIC_SW_SET 0x4000
#define AIC_SW_CLR 0x4080
#define AIC_MASK_SET 0x4100
#define AIC_MASK_CLR 0x4180
#define AIC_HW_STATE 0x4200
#define AIC_CPU_BASE 0x5000

#define AIC_NR_IRQ 896
#define AIC_INFO_VALUE 0x000a0380 /* value read from a real M1 (docs: dev-quickstart), NR_IRQ = 0x380 */
#define AIC_MAX_IRQ 0x400
#define AIC_WORDS (AIC_MAX_IRQ / 32)

#define AIC_EVENT_TYPE_IRQ 1
#define AIC_EVENT_TYPE_IPI 4
#define AIC_EVENT_IPI_OTHER 1
#define AIC_EVENT_IPI_SELF 2
#define AIC_IPI_OTHER (1u << 0)
#define AIC_IPI_SELF (1u << 31)

static struct {
    uint32_t config;
    uint32_t target[AIC_MAX_IRQ];
    uint32_t sw[AIC_WORDS], mask[AIC_WORDS];
    uint32_t ipi_pend[MAX_CPUS]; /* AIC_IPI_OTHER | AIC_IPI_SELF */
    uint32_t ipi_mask[MAX_CPUS];
} a;

void aic_init(void)
{
    memset(&a, 0, sizeof(a));
    for (int i = 0; i < AIC_WORDS; i++)
        a.mask[i] = 0xffffffffu; /* everything masked out of reset */
    for (int i = 0; i < AIC_MAX_IRQ; i++)
        a.target[i] = 1;
    for (int i = 0; i < MAX_CPUS; i++)
        a.ipi_mask[i] = AIC_IPI_OTHER | AIC_IPI_SELF;
}

static bool hw_level(int irq)
{
    if (irq == UART0_IRQ) return uart_irq_level();
    if (irq == INPUT_IRQ) return input_irq_level();
    if (irq >= BLK_IRQ_BASE && irq < BLK_IRQ_BASE + g.ndisks) return blk_irq_level(irq - BLK_IRQ_BASE);
    return false;
}

static bool irq_asserted(int irq)
{
    return ((a.sw[irq >> 5] >> (irq & 31)) & 1) || hw_level(irq);
}

static bool irq_pending_for(int irq, int cpu)
{
    if ((a.mask[irq >> 5] >> (irq & 31)) & 1)
        return false;
    if (!(a.target[irq] & (1u << cpu)))
        return false;
    return irq_asserted(irq);
}

static bool cpu_has_irq(int cpu)
{
    if (a.ipi_pend[cpu] & ~a.ipi_mask[cpu])
        return true;
    for (int irq = 0; irq < AIC_NR_IRQ; irq++)
        if (irq_pending_for(irq, cpu))
            return true;
    return false;
}

void aic_update_locked(void)
{
    for (int i = 0; i < g.ncpus; i++) {
        cpu_t *c = &g.cpus[i];
        bool now = cpu_has_irq(i);
        bool was = atomic_exchange(&c->irq_line, now);
        if (now != was)
            cpu_kick(c);
    }
}

/* EVENT register read: acknowledge the highest priority (lowest number) event. */
static uint32_t event_read(int cpu)
{
    uint32_t p = a.ipi_pend[cpu] & ~a.ipi_mask[cpu];
    if (p & AIC_IPI_OTHER) {
        a.ipi_mask[cpu] |= AIC_IPI_OTHER;
        return (AIC_EVENT_TYPE_IPI << 16) | AIC_EVENT_IPI_OTHER;
    }
    if (p & AIC_IPI_SELF) {
        a.ipi_mask[cpu] |= AIC_IPI_SELF;
        return (AIC_EVENT_TYPE_IPI << 16) | AIC_EVENT_IPI_SELF;
    }
    for (int irq = 0; irq < AIC_NR_IRQ; irq++) {
        if (irq_pending_for(irq, cpu)) {
            a.mask[irq >> 5] |= 1u << (irq & 31); /* auto-mask on ack */
            return (AIC_EVENT_TYPE_IRQ << 16) | (uint32_t)irq;
        }
    }
    return 0;
}

/* ---- Fast IPI (Apple IMP-DEF sysregs) ----------------------------------- */

static cpu_t *find_cpu(uint32_t cluster, uint32_t aff0, bool match_cluster)
{
    for (int i = 0; i < g.ncpus; i++) {
        cpu_t *t = &g.cpus[i];
        if ((t->mpidr & 0xff) == aff0 && (!match_cluster || ((t->mpidr >> 8) & 0xff) == cluster))
            return t;
    }
    return NULL;
}

/* SYS_IMP_APL_IPI_RR_{LOCAL,GLOBAL}_EL1 write. Fields (irq-apple-aic.c):
 * [7:0] cpu, [23:16] cluster (GLOBAL only), [29:28] type (0 immediate, 1 retract,
 * 2 deferred, 3 nowake). Deferred is treated as immediate (deviation). */
bool aic_fast_ipi_send(cpu_t *c, uint64_t val, bool global)
{
    uint32_t aff0 = val & 0xff, cluster = (val >> 16) & 0xff, type = (val >> 28) & 3;
    cpu_t *t;
    if (global)
        t = find_cpu(cluster, aff0, true);
    else
        t = find_cpu((c->mpidr >> 8) & 0xff, aff0, true);
    if (!t) {
        LOGE("cpu%d: fast IPI to nonexistent cpu (cluster %u cpu %u) ignored\n", c->idx, cluster, aff0);
        return true;
    }
    if (type == 1)
        atomic_store(&t->fipi_pending, false);
    else
        atomic_store(&t->fipi_pending, true);
    cpu_kick(t);
    return true;
}

/* IPI_SR read (clear=false) / write-1-to-clear (clear=true). Returns pending state. */
bool aic_fast_ipi_test_clear(cpu_t *c, bool clear)
{
    if (clear)
        return atomic_exchange(&c->fipi_pending, false);
    return atomic_load(&c->fipi_pending);
}

/* ---- MMIO --------------------------------------------------------------- */

const char *aic_regname(uint64_t off)
{
    static char buf[48];
    if (off == AIC_INFO) return "INFO";
    if (off == AIC_CONFIG) return "CONFIG";
    if (off == AIC_WHOAMI) return "WHOAMI";
    if (off == AIC_EVENT) return "EVENT";
    if (off == AIC_IPI_SEND) return "IPI_SEND";
    if (off == AIC_IPI_ACK) return "IPI_ACK";
    if (off == AIC_IPI_MASK_SET) return "IPI_MASK_SET";
    if (off == AIC_IPI_MASK_CLR) return "IPI_MASK_CLR";
    if (off >= AIC_TARGET_CPU && off < AIC_SW_SET) { snprintf(buf, sizeof buf, "TARGET_CPU[%llu]", (unsigned long long)(off - AIC_TARGET_CPU) / 4); return buf; }
    if (off >= AIC_SW_SET && off < AIC_SW_CLR) return "SW_SET";
    if (off >= AIC_SW_CLR && off < AIC_MASK_SET) return "SW_CLR";
    if (off >= AIC_MASK_SET && off < AIC_MASK_CLR) return "MASK_SET";
    if (off >= AIC_MASK_CLR && off < AIC_HW_STATE) return "MASK_CLR";
    if (off >= AIC_HW_STATE && off < AIC_HW_STATE + 0x80) return "HW_STATE";
    if (off >= AIC_CPU_BASE) return "CPU_VIEW";
    return "?";
}

static bool cpu_view(cpu_t *c, int cpu, uint32_t reg, bool wr, uint64_t *val)
{
    (void)c;
    if (cpu >= g.ncpus)
        return false;
    uint32_t v = (uint32_t)*val;
    switch (reg) {
    case 0x08: if (!wr) { *val = a.ipi_pend[cpu]; return true; } a.ipi_pend[cpu] |= v & (AIC_IPI_OTHER | AIC_IPI_SELF); break;
    case 0x0c: if (!wr) { *val = a.ipi_pend[cpu]; return true; } a.ipi_pend[cpu] &= ~v; break;
    case 0x24: if (!wr) { *val = a.ipi_mask[cpu]; return true; } a.ipi_mask[cpu] |= v; break;
    case 0x28: if (!wr) { *val = a.ipi_mask[cpu]; return true; } a.ipi_mask[cpu] &= ~v; break;
    default: return false;
    }
    aic_update_locked();
    return true;
}

bool aic_mmio(cpu_t *c, uint64_t off, int size, bool wr, uint64_t *val)
{
    if (size != 4) {
        LOGE("aic: unsupported %d-byte access at +0x%llx\n", size, (unsigned long long)off);
        return false;
    }
    uint32_t v = wr ? (uint32_t)*val : 0;
    uint32_t r = 0;

    if (off >= AIC_TARGET_CPU && off < AIC_TARGET_CPU + 4 * AIC_MAX_IRQ) {
        int irq = (int)((off - AIC_TARGET_CPU) / 4);
        if (wr) a.target[irq] = v; else r = a.target[irq];
    } else if (off >= AIC_SW_SET && off < AIC_HW_STATE + 4 * AIC_WORDS) {
        int w = (int)((off & 0x7f) / 4);
        uint64_t bank = off & ~0x7fULL;
        if (bank == AIC_SW_SET) { if (wr) a.sw[w] |= v; else r = a.sw[w]; }
        else if (bank == AIC_SW_CLR) { if (wr) a.sw[w] &= ~v; else r = a.sw[w]; }
        else if (bank == AIC_MASK_SET) { if (wr) a.mask[w] |= v; else r = a.mask[w]; }
        else if (bank == AIC_MASK_CLR) { if (wr) a.mask[w] &= ~v; else r = a.mask[w]; }
        else if (bank == AIC_HW_STATE) {
            if (wr) return false;
            for (int b = 0; b < 32; b++)
                if (hw_level(w * 32 + b))
                    r |= 1u << b;
        } else return false;
    } else if (off >= AIC_CPU_BASE && off < AIC_CPU_BASE + (MAX_CPUS << 7)) {
        uint64_t val64 = v;
        bool ok = cpu_view(c, (int)((off - AIC_CPU_BASE) >> 7), (uint32_t)((off - AIC_CPU_BASE) & 0x7f), wr, &val64);
        if (!ok) return false;
        if (!wr) *val = val64;
        return true;
    } else {
        switch (off) {
        case AIC_INFO: if (wr) return false; r = AIC_INFO_VALUE; break;
        case AIC_CONFIG: if (wr) a.config = v; else r = a.config; break;
        case AIC_WHOAMI: if (wr) return false; r = (uint32_t)c->idx; break;
        case AIC_EVENT: if (wr) return false; r = event_read(c->idx); break;
        case AIC_IPI_SEND:
            if (!wr) return false;
            for (int i = 0; i < g.ncpus; i++) {
                if (v & (1u << i)) a.ipi_pend[i] |= AIC_IPI_OTHER;
            }
            if (v & AIC_IPI_SELF)
                a.ipi_pend[c->idx] |= AIC_IPI_SELF;
            break;
        case AIC_IPI_ACK:
            if (!wr) return false;
            a.ipi_pend[c->idx] &= ~v;
            break;
        case AIC_IPI_MASK_SET: if (wr) a.ipi_mask[c->idx] |= v; else r = a.ipi_mask[c->idx]; break;
        case AIC_IPI_MASK_CLR: if (wr) a.ipi_mask[c->idx] &= ~v; else r = a.ipi_mask[c->idx]; break;
        default:
            LOGE("aic: %s of unknown register +0x%llx\n", wr ? "write" : "read", (unsigned long long)off);
            return false;
        }
    }
    if (wr)
        aic_update_locked();
    else
        *val = r;
    if (!wr && off == AIC_EVENT)
        aic_update_locked(); /* auto-mask changed the line */
    return true;
}
