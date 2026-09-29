/*
 * vCPU threads: run loop, exit handling (MMIO data aborts, IMP-DEF sysreg
 * traps, HVC, WFI/WFE, virtual timer), spin-table secondary bring-up.
 */
#include "coolvm.h"

#include <libkern/OSCacheControl.h>
#include <pthread/qos.h>
#include <sys/event.h>
#include <time.h>
#include <unistd.h>

/* ARM ESR_ELx exception classes */
#define EC_WFX 0x01
#define EC_HVC64 0x16
#define EC_SMC64 0x17
#define EC_SYSREG 0x18
#define EC_IABT_LOWER 0x20
#define EC_DABT_LOWER 0x24

#define CPSR_EL1H_MASKED 0x3c5ULL /* D A I F masked, EL1h */

#define SR(op0, op1, crn, crm, op2) (((op0) << 14) | ((op1) << 11) | ((crn) << 7) | ((crm) << 3) | (op2))
/* Apple IMP-DEF registers, linux drivers/irqchip/irq-apple-aic.c and arch/arm64/include/asm/apple_m1_pmu.h */
#define SR_IPI_RR_LOCAL SR(3, 5, 15, 0, 0)
#define SR_IPI_RR_GLOBAL SR(3, 5, 15, 0, 1)
#define SR_IPI_SR SR(3, 5, 15, 1, 1)
#define SR_VM_TMR_FIQ_ENA SR(3, 5, 15, 1, 3)
#define SR_IPI_CR SR(3, 5, 15, 3, 1)
#define SR_PMCR0 SR(3, 1, 15, 0, 0)
#define SR_UPMCR0 SR(3, 7, 15, 0, 4)
#define SR_UPMSR SR(3, 7, 15, 6, 4)
#define SR_CNTPCT SR(3, 3, 14, 0, 1) /* traps under Hypervisor.framework */

#define PSCI_SYSTEM_OFF 0x84000008ULL
#define PSCI_SYSTEM_RESET 0x84000009ULL
#define COOLVM_HVC_EXIT 0xC001 /* hvc #0xC001, x0 = exit status (VM-only) */

static _Atomic bool poker_run;
static bool verbose;

void cpu_set_verbose(bool v) { verbose = v; }

/* ---- helpers ------------------------------------------------------------ */

static uint64_t gpr(cpu_t *c, unsigned n)
{
    uint64_t v = 0;
    if (n < 31)
        hv_vcpu_get_reg(c->vcpu, HV_REG_X0 + n, &v);
    return v;
}

static void gpr_set(cpu_t *c, unsigned n, uint64_t v)
{
    if (n < 31)
        hv_vcpu_set_reg(c->vcpu, HV_REG_X0 + n, v);
}

static uint64_t get_pc(cpu_t *c)
{
    uint64_t v = 0;
    hv_vcpu_get_reg(c->vcpu, HV_REG_PC, &v);
    return v;
}

static void set_pc(cpu_t *c, uint64_t v)
{
    hv_vcpu_set_reg(c->vcpu, HV_REG_PC, v);
}

static uint64_t cntpct(void)
{
    uint64_t v;
    __asm__ volatile("isb\n\tmrs %0, cntpct_el0" : "=r"(v));
    return v;
}

void cpu_kick(cpu_t *c)
{
    struct kevent ke;
    EV_SET(&ke, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0, NULL);
    kevent(c->kq, &ke, 1, NULL, 0, NULL);
    if (atomic_load(&c->started))
        hv_vcpus_exit(&c->vcpu, 1);
}

void vm_stop(int code, const char *why)
{
    pthread_mutex_lock(&g.stop_lock);
    if (!atomic_load(&g.stop)) {
        atomic_store(&g.exit_code, code);
        if (why && verbose)
            LOGE("stopping: %s (exit code %d)\n", why, code);
        atomic_store(&g.stop, true);
    }
    pthread_cond_broadcast(&g.stop_cv);
    pthread_mutex_unlock(&g.stop_lock);
    for (int i = 0; i < g.ncpus; i++)
        cpu_kick(&g.cpus[i]);
}

static void dump_state(cpu_t *c)
{
    uint64_t esr = c->exit ? c->exit->exception.syndrome : 0;
    uint64_t far = c->exit ? c->exit->exception.virtual_address : 0;
    uint64_t ipa = c->exit ? c->exit->exception.physical_address : 0;
    uint64_t cpsr = 0, elr = 0, vbar = 0;
    hv_vcpu_get_reg(c->vcpu, HV_REG_CPSR, &cpsr);
    hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_ELR_EL1, &elr);
    hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_VBAR_EL1, &vbar);
    fprintf(stderr, "coolvm: cpu%d state: pc=0x%llx cpsr=0x%llx esr=0x%llx far=0x%llx ipa=0x%llx elr_el1=0x%llx vbar_el1=0x%llx\n",
            c->idx, (unsigned long long)get_pc(c), (unsigned long long)cpsr, (unsigned long long)esr,
            (unsigned long long)far, (unsigned long long)ipa, (unsigned long long)elr, (unsigned long long)vbar);
    for (int i = 0; i < 31; i += 4) {
        fprintf(stderr, "  ");
        for (int j = i; j < i + 4 && j < 31; j++)
            fprintf(stderr, "x%-2d=%016llx ", j, (unsigned long long)gpr(c, j));
        fprintf(stderr, "\n");
    }
}

static void fatal(cpu_t *c, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
#include <stdarg.h>
static void fatal(cpu_t *c, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "coolvm: FATAL cpu%d: ", c->idx);
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
    dump_state(c);
    vm_stop(1, "fatal guest fault");
}

/* Reflect an UNDEF (unknown reason, EC=0) into the guest at EL1, like the CPU
 * would for an unimplemented IMP-DEF system register. */
static void inject_undef(cpu_t *c, uint64_t pc)
{
    uint64_t cpsr = 0, vbar = 0;
    hv_vcpu_get_reg(c->vcpu, HV_REG_CPSR, &cpsr);
    hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_VBAR_EL1, &vbar);
    uint64_t off = 0x200; /* current EL, SPx */
    switch (cpsr & 0xf) {
    case 0x0: off = 0x400; break; /* from EL0 */
    case 0x4: off = 0x000; break; /* EL1t */
    default: break;
    }
    hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_ESR_EL1, 0x02000000ULL);
    hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_ELR_EL1, pc);
    hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_SPSR_EL1, cpsr);
    set_pc(c, vbar + off);
    hv_vcpu_set_reg(c->vcpu, HV_REG_CPSR, CPSR_EL1H_MASKED);
}

/* ---- virtual timer ------------------------------------------------------
 *
 * Hypervisor.framework protocol: when the guest's CNTV fires, hv_vcpu_run
 * returns HV_EXIT_REASON_VTIMER_ACTIVATED and the framework sets its "vtimer
 * mask" so the exit does not repeat until hv_vcpu_set_vtimer_mask(false).
 * On M1 the timer is a FIQ (aic_fiq_*, aic_handle_fiq()), and the guest kernel
 * handles it by masking/reprogramming CNTV_CTL/CVAL natively (no trap), so we
 * cannot see the "EOI". Emulation:
 *   - on activation: assert the FIQ line (timer_fiq) and keep the host mask;
 *   - when the guest reads IPI_SR_EL1 (trapped IMP-DEF sysreg; every M1 FIQ
 *     handler does this first, aic_handle_fiq()) we treat that as FIQ entry
 *     and deassert the line (await_clear);
 *   - on every exit and every ~250us tick from the poker thread while the host
 *     mask is set (vtimer_sync), re-read CNTV_CTL: once the condition
 *     (ENABLE && ISTATUS && !IMASK) is gone, or CVAL changed after FIQ entry,
 *     clear the host mask so the next
 *     expiry exits again.
 * Deviation: a handler that never quiesces the timer is not re-interrupted
 * (edge-like), and re-arm latency is up to ~250us.
 */
static void vtimer_sync(cpu_t *c)
{
    if (!c->vt_host_masked)
        return;
    uint64_t ctl = 0, cval = 0;
    hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_CNTV_CTL_EL0, &ctl);
    hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_CNTV_CVAL_EL0, &cval);
    bool firing = (ctl & 7) == 5; /* ENABLE=1, IMASK=0, ISTATUS=1 */
    /* A busy host may miss the entire quiet interval between 1 ms ticks.
     * A different CVAL after FIQ entry proves the guest rearmed the timer,
     * even when that new deadline has already passed. Unmask it so HVF can
     * deliver that next expiration instead of leaving WFI asleep forever. */
    if (!firing || (c->vt_await_clear && cval != c->vt_fired_cval)) {
        hv_vcpu_set_vtimer_mask(c->vcpu, false);
        atomic_store(&c->vt_host_masked, false);
        c->timer_fiq = false;
        c->vt_await_clear = false;
    } else if (!c->vt_await_clear) {
        c->timer_fiq = true;
    }
}

static void apply_lines(cpu_t *c)
{
    /* Hypervisor.framework clears pending interrupts every time hv_vcpu_run returns, so the
     * (level) lines must be re-asserted before every run. Any exit (every AIC EVENT read, every
     * IPI_SR_EL1 read) therefore acts as an implicit "line taken" edge, after which the
     * models below decide whether the line is still asserted. */
    bool irq = atomic_load(&c->irq_line);
    bool fiq = atomic_load(&c->fipi_pending) || c->timer_fiq;
    if (irq)
        hv_vcpu_set_pending_interrupt(c->vcpu, HV_INTERRUPT_TYPE_IRQ, true);
    if (fiq)
        hv_vcpu_set_pending_interrupt(c->vcpu, HV_INTERRUPT_TYPE_FIQ, true);
}

static bool lines_asserted(cpu_t *c)
{
    return atomic_load(&c->irq_line) || atomic_load(&c->fipi_pending) || c->timer_fiq;
}

/* WFI: sleep until an interrupt line is asserted, the guest timer is due, or
 * stop. Spurious returns are architecturally fine. */
static void do_wfi(cpu_t *c)
{
    const uint64_t spin_ns = 100 * 1000; /* the last stretch before a timer deadline is spun, not slept */
    for (;;) {
        vtimer_sync(c);
        if (lines_asserted(c) || atomic_load(&g.stop))
            return;
        uint64_t ns = 50ULL * 1000 * 1000; /* safety cap; lines wake us through the kqueue */
        int64_t due_ns = -1;               /* time until the guest timer fires */
        if (atomic_load(&c->vt_host_masked)) {
            ns = 250ULL * 1000; /* waiting for the guest to quiesce the timer */
        } else {
            uint64_t ctl = 0, cval = 0;
            hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_CNTV_CTL_EL0, &ctl);
            if ((ctl & 3) == 1) { /* enabled and not masked */
                hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_CNTV_CVAL_EL0, &cval);
                int64_t diff = (int64_t)(cval - (cntpct() - g.cntvoff));
                if (diff <= 0)
                    return; /* due: let the hypervisor report VTIMER_ACTIVATED */
                due_ns = diff * 1000000000LL / (int64_t)g.cntfrq;
            }
        }
        if (due_ns >= 0 && (uint64_t)due_ns <= spin_ns) {
            /* spin until due (or a line asserts), then return so hv_vcpu_run reports the timer */
            while (!lines_asserted(c) && !atomic_load(&g.stop)) {
                uint64_t cval = 0;
                hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_CNTV_CVAL_EL0, &cval);
                if ((int64_t)(cval - (cntpct() - g.cntvoff)) <= 0)
                    break;
                __asm__ volatile("yield");
            }
            return;
        }
        if (due_ns >= 0 && (uint64_t)due_ns - spin_ns < ns)
            ns = (uint64_t)due_ns - spin_ns;
        /* Sleep until a line changes (EVFILT_USER) or the deadline (EVFILT_TIMER). NOTE_CRITICAL
         * asks the kernel not to coalesce the timer; a plain condvar/nanosleep can oversleep by
         * ~2 ms which shows up as timer-interrupt jitter in the guest. A trigger that arrives
         * between the line check above and this call stays latched, so no wakeup is lost. */
        struct kevent ch[2], out;
        EV_SET(&ch[0], 2, EVFILT_TIMER, EV_ADD | EV_ONESHOT, NOTE_NSECONDS | NOTE_CRITICAL, (intptr_t)ns, NULL);
        kevent(c->kq, ch, 1, &out, 1, NULL);
        EV_SET(&ch[1], 2, EVFILT_TIMER, EV_DELETE, 0, 0, NULL);
        kevent(c->kq, &ch[1], 1, NULL, 0, NULL); /* drop it if the trigger won the race */
    }
}

/* ---- MMIO --------------------------------------------------------------- */

static bool region_dispatch(cpu_t *c, uint64_t pa, int size, bool wr, uint64_t *val, const char **dev,
                            const char **reg, uint64_t *offp)
{
    bool ok;
    if (pa >= UART0_BASE && pa < UART0_BASE + UART0_SIZE) {
        uint64_t off = pa - UART0_BASE;
        *dev = "uart0";
        *reg = uart_regname(off);
        *offp = off;
        ok = uart_mmio(c, off, size, wr, val);
    } else if (pa >= AIC_BASE && pa < AIC_BASE + AIC_SIZE) {
        uint64_t off = pa - AIC_BASE;
        *dev = "aic";
        *reg = aic_regname(off);
        *offp = off;
        ok = aic_mmio(c, off, size, wr, val);
    } else if (pa >= FINISHER_BASE && pa < FINISHER_BASE + FINISHER_SIZE) {
        *dev = "finisher";
        *reg = "FINISH";
        *offp = pa - FINISHER_BASE;
        ok = true;
        if (wr && *offp == 0) {
            uint32_t v = (uint32_t)*val;
            if ((v & 0xffff) == 0x5555)
                vm_stop(0, "finisher: power off");
            else if ((v & 0xffff) == 0x7777) {
                atomic_store(&g.reset, true);
                vm_stop(0, "finisher: reset");
            }
            else if ((v & 0xffff) == 0x3333)
                vm_stop((int)(v >> 16) & 0xff, "finisher: exit");
            else
                ok = false;
        } else if (wr && *offp >= FINISHER_BOOT_ADDR && *offp < FINISHER_BOOT_SIZE + 8 &&
                   (size == 4 || (size == 8 && !(*offp & 7)))) {
            uint64_t *r = *offp < FINISHER_BOOT_SIZE ? &g.boot_addr : &g.boot_size;
            if (size == 8)
                *r = *val;
            else if (*offp & 4)
                *r = (*r & 0xffffffffULL) | (uint64_t)(uint32_t)*val << 32;
            else
                *r = (*r & ~0xffffffffULL) | (uint32_t)*val;
        } else if (wr || *offp != 0) {
            ok = false;
        } else {
            *val = 0;
        }
    } else if (pa >= INPUT_BASE && pa < INPUT_BASE + INPUT_SIZE) {
        *dev = "input"; *reg = "FIFO"; *offp = pa - INPUT_BASE;
        ok = input_mmio(*offp, size, wr, val);
    } else if (pa >= BLK_BASE && pa < BLK_BASE + BLK_STRIDE * (uint64_t)g.ndisks) {
        int disk = (int)((pa - BLK_BASE) / BLK_STRIDE);
        *dev = "virtio-blk"; *reg = "MMIO"; *offp = (pa - BLK_BASE) % BLK_STRIDE;
        ok = blk_mmio(disk, *offp, size, wr, val);
    } else if (g.net && pa >= NET_BASE && pa < NET_BASE + NET_SIZE) {
        *dev = "virtio-net"; *reg = "MMIO"; *offp = pa - NET_BASE;
        ok = net_mmio(*offp, size, wr, val);
    } else {
        *dev = NULL;
        return false;
    }
    return ok;
}

static void handle_dabort(cpu_t *c, uint64_t esr, uint64_t ipa)
{
    uint64_t pc = get_pc(c);
    bool isv = (esr >> 24) & 1;
    bool wr = (esr >> 6) & 1;
    if (!isv) {
        fatal(c, "data abort at IPA 0x%llx without valid syndrome (paired/atomic/exclusive access to unmapped or MMIO space?) pc=0x%llx",
              (unsigned long long)ipa, (unsigned long long)pc);
        return;
    }
    int size = 1 << ((esr >> 22) & 3);
    bool sse = (esr >> 21) & 1;
    unsigned srt = (esr >> 16) & 31;
    bool sf = (esr >> 15) & 1;
    uint64_t val = 0;
    if (wr)
        val = gpr(c, srt) & (size == 8 ? ~0ULL : ((1ULL << (size * 8)) - 1));

    const char *dev = NULL, *reg = "";
    uint64_t off = 0;
    pthread_mutex_lock(&g.lock);
    bool ok = region_dispatch(c, ipa, size, wr, &val, &dev, &reg, &off);
    pthread_mutex_unlock(&g.lock);

    if (g.trace_mmio) {
        if (dev)
            fprintf(stderr, "mmio cpu%d %s%d %s+0x%llx (%s) %s 0x%llx  pc=0x%llx%s\n", c->idx, wr ? "W" : "R", size * 8,
                    dev, (unsigned long long)off, reg, wr ? "<=" : "=>", (unsigned long long)val, (unsigned long long)pc,
                    ok ? "" : "  [FAULT]");
        else
            fprintf(stderr, "mmio cpu%d %s%d 0x%llx UNMAPPED pc=0x%llx\n", c->idx, wr ? "W" : "R", size * 8,
                    (unsigned long long)ipa, (unsigned long long)pc);
    }
    if (!dev) {
        if (g.lenient) {
            LOGE("cpu%d: unknown MMIO %s%d at 0x%llx (pc=0x%llx): %s\n", c->idx, wr ? "write" : "read", size * 8,
                 (unsigned long long)ipa, (unsigned long long)pc, wr ? "ignored" : "read as 0");
            val = 0;
        } else {
            fatal(c, "unhandled MMIO %s of %d bytes at 0x%llx (value 0x%llx) pc=0x%llx  [--lenient makes unknown MMIO RAZ/WI]",
                  wr ? "write" : "read", size, (unsigned long long)ipa, (unsigned long long)val, (unsigned long long)pc);
            return;
        }
    } else if (!ok) {
        fatal(c, "%s rejected %s%d access at 0x%llx (%s+0x%llx) pc=0x%llx", dev, wr ? "write" : "read", size * 8,
              (unsigned long long)ipa, reg, (unsigned long long)off, (unsigned long long)pc);
        return;
    }
    if (!wr) {
        if (sse && size < 8) {
            int sh = 64 - size * 8;
            val = (uint64_t)((int64_t)(val << sh) >> sh);
            if (!sf)
                val &= 0xffffffffULL;
        }
        gpr_set(c, srt, val);
    }
    set_pc(c, pc + 4);
}

/* ---- system registers --------------------------------------------------- */

static void handle_sysreg(cpu_t *c, uint64_t esr)
{
    uint64_t pc = get_pc(c);
    unsigned op0 = (esr >> 20) & 3, op2 = (esr >> 17) & 7, op1 = (esr >> 14) & 7;
    unsigned crn = (esr >> 10) & 15, rt = (esr >> 5) & 31, crm = (esr >> 1) & 15;
    bool rd = esr & 1;
    unsigned enc = SR(op0, op1, crn, crm, op2);
    uint64_t v = rd ? 0 : gpr(c, rt);
    const char *name = NULL;
    uint64_t *scratch = NULL;

    switch (enc) {
    case SR_IPI_RR_LOCAL:
        name = "IPI_RR_LOCAL_EL1";
        if (!rd)
            aic_fast_ipi_send(c, v, false);
        break;
    case SR_IPI_RR_GLOBAL:
        name = "IPI_RR_GLOBAL_EL1";
        if (!rd)
            aic_fast_ipi_send(c, v, true);
        break;
    case SR_IPI_SR:
        name = "IPI_SR_EL1";
        if (rd) {
            v = aic_fast_ipi_test_clear(c, false) ? 1 : 0;
            /* every M1 FIQ handler starts by reading this: FIQ entry => deassert timer line */
            if (c->timer_fiq) {
                c->timer_fiq = false;
                c->vt_await_clear = true;
            }
        } else if (v & 1) {
            aic_fast_ipi_test_clear(c, true);
        }
        break;
    case SR_VM_TMR_FIQ_ENA: name = "VM_TMR_FIQ_ENA_EL2"; scratch = &c->vm_tmr_fiq_ena; break;
    case SR_IPI_CR: name = "IPI_CR_EL1"; scratch = &c->ipi_cr; break;
    case SR_PMCR0: name = "PMCR0_EL1"; scratch = &c->pmcr0; break;
    case SR_UPMCR0: name = "UPMCR0_EL1"; scratch = &c->upmcr0; break;
    case SR_UPMSR: name = "UPMSR_EL1"; if (!rd) name = NULL; break; /* RO: reads 0 */
    case SR_CNTPCT:
        if (rd) {
            name = "CNTPCT_EL0";
            v = cntpct();
        }
        break;
    default: break;
    }

    if (!name && g.el2) {
        /* EL2 mode: EL2 registers that Hypervisor.framework virtualizes in software trap to us;
         * the hv_sys_reg_t values use the same op0/op1/CRn/CRm/op2 packing as SR(). */
        uint64_t hv = 0;
        hv_return_t hr;
        if (rd)
            hr = hv_vcpu_get_sys_reg(c->vcpu, (hv_sys_reg_t)enc, &hv);
        else
            hr = hv_vcpu_set_sys_reg(c->vcpu, (hv_sys_reg_t)enc, v);
        if (hr == HV_SUCCESS) {
            if (g.trace_mmio)
                fprintf(stderr, "sysreg cpu%d %s S%u_%u_C%u_C%u_%u (forwarded to hv) 0x%llx pc=0x%llx\n", c->idx, rd ? "R" : "W",
                        op0, op1, crn, crm, op2, (unsigned long long)(rd ? hv : v), (unsigned long long)pc);
            if (rd)
                gpr_set(c, rt, hv);
            set_pc(c, pc + 4);
            return;
        }
    }
    if (!name) {
        LOGE("cpu%d: UNKNOWN system register %s S%u_%u_C%u_C%u_%u pc=0x%llx%s\n", c->idx, rd ? "read" : "write", op0, op1,
             crn, crm, op2, (unsigned long long)pc, rd ? "" : "");
        if (g.strict) {
            fatal(c, "unknown sysreg access S%u_%u_C%u_C%u_%u (--strict)", op0, op1, crn, crm, op2);
            return;
        }
        LOGE("cpu%d: injecting UNDEF into the guest\n", c->idx);
        inject_undef(c, pc);
        return;
    }
    if (scratch) {
        if (rd)
            v = *scratch;
        else
            *scratch = v;
    }
    if (g.trace_mmio)
        fprintf(stderr, "sysreg cpu%d %s %s %s 0x%llx  pc=0x%llx\n", c->idx, rd ? "R" : "W", name, rd ? "=>" : "<=",
                (unsigned long long)v, (unsigned long long)pc);
    if (rd)
        gpr_set(c, rt, v);
    set_pc(c, pc + 4);
}

/* ---- exit dispatch ------------------------------------------------------ */

static void handle_hvc(cpu_t *c, uint64_t esr)
{
    unsigned imm = esr & 0xffff;
    uint64_t x0 = gpr(c, 0);
    /* HVF reports HVC with PC already past the instruction (preferred return address). */
    if (imm == 0 && (x0 == PSCI_SYSTEM_OFF || x0 == PSCI_SYSTEM_RESET)) {
        if (verbose || g.trace_mmio)
            LOGE("cpu%d: PSCI %s hypercall -> power off\n", c->idx, x0 == PSCI_SYSTEM_OFF ? "SYSTEM_OFF" : "SYSTEM_RESET");
        vm_stop(0, "guest powered off");
        return;
    }
    if (imm == COOLVM_HVC_EXIT) {
        vm_stop((int)(x0 & 0xff), "guest exit hypercall");
        return;
    }
    LOGE("cpu%d: unknown HVC #0x%x x0=0x%llx: returning -1 (NOT_SUPPORTED)\n", c->idx, imm, (unsigned long long)x0);
    gpr_set(c, 0, (uint64_t)-1);
}

static void handle_exception(cpu_t *c)
{
    uint64_t esr = c->exit->exception.syndrome;
    uint64_t ipa = c->exit->exception.physical_address;
    unsigned ec = (esr >> 26) & 0x3f;
    switch (ec) {
    case EC_WFX:
        set_pc(c, get_pc(c) + 4);
        if ((esr & 1) == 0) {
            do_wfi(c);
        } else {
            /* WFE: cheap yield; guests use it in spin loops (spin-table holding pen) */
            struct timespec ts = {0, 20000};
            nanosleep(&ts, NULL);
        }
        break;
    case EC_HVC64:
        handle_hvc(c, esr);
        break;
    case EC_SMC64:
        LOGE("cpu%d: SMC #0x%llx x0=0x%llx (no EL3/PSCI-via-SMC on this platform): injecting UNDEF\n", c->idx,
             (unsigned long long)(esr & 0xffff), (unsigned long long)gpr(c, 0));
        inject_undef(c, get_pc(c));
        break;
    case EC_SYSREG:
        handle_sysreg(c, esr);
        break;
    case EC_DABT_LOWER:
        handle_dabort(c, esr, ipa);
        break;
    case EC_IABT_LOWER:
        fatal(c, "instruction abort at IPA 0x%llx (guest executed from unmapped memory), esr=0x%llx", (unsigned long long)ipa,
              (unsigned long long)esr);
        break;
    default:
        fatal(c, "unhandled exception class 0x%x esr=0x%llx", ec, (unsigned long long)esr);
        break;
    }
}

/* ---- thread ------------------------------------------------------------- */

#define SCTLR_EL1_INIT 0x30d00800ULL /* RES1 bits only: MMU off, caches off */

static bool vcpu_create(cpu_t *c, uint64_t entry, uint64_t x0)
{
    hv_return_t r = hv_vcpu_create(&c->vcpu, &c->exit, NULL);
    if (r != HV_SUCCESS) {
        LOGE("hv_vcpu_create(cpu%d) failed: 0x%x\n", c->idx, r);
        vm_stop(1, "vcpu create failed");
        return false;
    }
    if (g.el2) {
        r = hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_VMPIDR_EL2, c->mpidr);
        if (r != HV_SUCCESS)
            LOGE("cpu%d: setting VMPIDR_EL2 failed: 0x%x\n", c->idx, r);
        /* Hand-over state of m1n1 (src/exception.c): E2H|TGE (VHE host), RW, AMO|IMO|FMO,
         * TEA, API|APK; SCTLR_EL2 has MMU and caches off. */
        hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_HCR_EL2,
                            (1ULL << 41) | (1ULL << 40) | (1ULL << 37) | (1ULL << 34) | (1ULL << 31) |
                                (1ULL << 27) | (1ULL << 5) | (1ULL << 4) | (1ULL << 3));
        hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_SCTLR_EL2, 0x30c50830ULL);
        if (verbose) {
            uint64_t hcr = 0, mp = 0;
            hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_HCR_EL2, &hcr);
            hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_MPIDR_EL1, &mp);
            LOGE("cpu%d: EL2 guest: HCR_EL2=0x%llx MPIDR_EL1=0x%llx\n", c->idx, (unsigned long long)hcr, (unsigned long long)mp);
        }
        hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_CPTR_EL2, 3ULL << 20 | (1ULL << 28)); /* E2H: FPEN=3 */
    } else {
        r = hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_MPIDR_EL1, c->mpidr);
        if (r != HV_SUCCESS)
            LOGE("cpu%d: setting MPIDR_EL1 failed: 0x%x (guest will see the host's)\n", c->idx, r);
    }
    hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_SCTLR_EL1, SCTLR_EL1_INIT);
    hv_vcpu_set_sys_reg(c->vcpu, HV_SYS_REG_CPACR_EL1, 3ULL << 20); /* FP/SIMD not trapped */
    hv_vcpu_set_vtimer_offset(c->vcpu, g.cntvoff);
    for (int i = 0; i < 31; i++)
        hv_vcpu_set_reg(c->vcpu, HV_REG_X0 + i, 0);
    hv_vcpu_set_reg(c->vcpu, HV_REG_X0, x0);
    hv_vcpu_set_reg(c->vcpu, HV_REG_CPSR, g.el2 ? 0x3c9ULL : CPSR_EL1H_MASKED);
    hv_vcpu_set_reg(c->vcpu, HV_REG_PC, entry);
    atomic_store(&c->started, true);
    return true;
}

static void poker_wake(void);

static void run_loop(cpu_t *c)
{
    while (!atomic_load(&g.stop)) {
        vtimer_sync(c);
        apply_lines(c);
        hv_return_t r = hv_vcpu_run(c->vcpu);
        if (r != HV_SUCCESS) {
            LOGE("cpu%d: hv_vcpu_run failed: 0x%x\n", c->idx, r);
            vm_stop(1, "hv_vcpu_run failed");
            break;
        }
        switch (c->exit->reason) {
        case HV_EXIT_REASON_CANCELED:
            break;
        case HV_EXIT_REASON_VTIMER_ACTIVATED:
            /* framework has set the vtimer mask; see the protocol comment above */
            hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_CNTV_CVAL_EL0, &c->vt_fired_cval);
            atomic_store(&c->vt_host_masked, true);
            poker_wake();
            c->timer_fiq = true;
            c->vt_await_clear = false;
            if (verbose)
            {
                uint64_t cv = 0;
                hv_vcpu_get_sys_reg(c->vcpu, HV_SYS_REG_CNTV_CVAL_EL0, &cv);
                LOGE("cpu%d: vtimer activated, %lld us after CVAL\n", c->idx,
                     (long long)(((int64_t)((cntpct() - g.cntvoff) - cv)) * 1000000 / (int64_t)g.cntfrq));
            }
            break;
        case HV_EXIT_REASON_EXCEPTION:
            handle_exception(c);
            break;
        default:
            fatal(c, "unknown exit reason %d", c->exit->reason);
            break;
        }
    }
}

extern uint64_t board_spin_target_addr(int idx);

void *cpu_thread_main(void *arg)
{
    cpu_t *c = arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    uint64_t entry = c->boot_entry, x0 = c->boot_x0;

    if (c->idx != 0) {
        /* m1n1 parks secondaries in a WFE/IPI loop on spin_table[i].target (kboot.c sets
         * cpu-release-addr to &spin_table[i].target). Poll it host-side. */
        atomic_store(&c->parked, true);
        volatile uint64_t *tgt = (volatile uint64_t *)(g.ram + (board_spin_target_addr(c->idx) - DRAM_BASE));
        for (;;) {
            if (atomic_load(&g.stop))
                return NULL;
            sys_dcache_flush((void *)tgt, 8);
            uint64_t v = *tgt;
            if (v) {
                entry = v;
                x0 = tgt[1]; /* args[0] */
                break;
            }
            usleep(200);
        }
        atomic_store(&c->parked, false);
        if (verbose)
            LOGE("cpu%d: released to 0x%llx\n", c->idx, (unsigned long long)entry);
    }
    if (!vcpu_create(c, entry, x0))
        return NULL;
    run_loop(c);
    atomic_store(&c->started, false);
    hv_vcpu_destroy(c->vcpu);
    return NULL;
}

static pthread_mutex_t poker_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t poker_cv = PTHREAD_COND_INITIALIZER;

static bool any_vtimer_masked(void)
{
    for (int i = 0; i < g.ncpus; i++)
        if (atomic_load(&g.cpus[i].started) && atomic_load(&g.cpus[i].vt_host_masked))
            return true;
    return false;
}

/* Wake the poker: a vCPU just went into the "vtimer host-masked" state. */
static void poker_wake(void)
{
    pthread_mutex_lock(&poker_mtx);
    pthread_cond_signal(&poker_cv);
    pthread_mutex_unlock(&poker_mtx);
}

/* While any vCPU has its Hypervisor.framework vtimer mask set, force that vCPU out of
 * the guest every ~200us so vtimer_sync() can notice the guest quiesced the timer. */
static void *poker_main(void *arg)
{
    (void)arg;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    while (atomic_load(&poker_run) && !atomic_load(&g.stop)) {
        pthread_mutex_lock(&poker_mtx);
        while (atomic_load(&poker_run) && !atomic_load(&g.stop) && !any_vtimer_masked()) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            ts.tv_nsec += 20 * 1000 * 1000;
            if (ts.tv_nsec >= 1000000000L) {
                ts.tv_sec++;
                ts.tv_nsec -= 1000000000L;
            }
            pthread_cond_timedwait(&poker_cv, &poker_mtx, &ts);
        }
        pthread_mutex_unlock(&poker_mtx);
        usleep(150);
        for (int i = 0; i < g.ncpus; i++) {
            cpu_t *c = &g.cpus[i];
            if (atomic_load(&c->started) && atomic_load(&c->vt_host_masked))
                hv_vcpus_exit(&c->vcpu, 1);
        }
    }
    return NULL;
}

static pthread_t poker_th;

void cpu_timer_poker_start(void)
{
    atomic_store(&poker_run, true);
    pthread_create(&poker_th, NULL, poker_main, NULL);
}

void cpu_timer_poker_stop(void)
{
    atomic_store(&poker_run, false);
    poker_wake();
    pthread_join(poker_th, NULL);
}
