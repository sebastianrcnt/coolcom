// coolvm test guest: a Linux arm64 Image (header, entered at EL1h, MMU off) that
// exercises everything coolvm emulates, using the M1 hardware interfaces only:
//   - s5l UART at 0x235200000 (polled TX, TX-threshold IRQ through AIC hwirq 605)
//   - device tree passed in x0 (root compatible, memory node, cpu@1 release address)
//   - AIC at 0x23b100000: INFO/WHOAMI, MASK_CLR/SW_SET/SW_CLR, EVENT ack, IRQ vector
//   - virtual timer delivered as FIQ (IPI_SR_EL1 is read first, as aic_handle_fiq() does)
//   - unknown IMP-DEF sysreg -> UNDEF
//   - secondary CPU start via spin-table release address (cpu-release-addr), then a
//     fast IPI (IPI_RR_LOCAL_EL1) from cpu0 to cpu1 taken as a FIQ
//   - power off via the PSCI SYSTEM_OFF hypercall (VM-only)
// Position independent (adr only); link address is irrelevant.

        .equ UART_BASE,   0x235200000
        .equ AIC_BASE,    0x23b100000
        .equ UART_IRQ,    605
        .equ TEST_IRQ,    100

        .section .text
        .globl _start
_start:
        b       start                   // code0
        .word   0                       // code1
        .quad   0                       // text_offset
        .quad   image_end - _start      // image_size
        .quad   0xa                     // flags: LE, 4K pages, placement anywhere
        .quad   0, 0, 0                 // res2-4
        .word   0x644d5241              // magic "ARM\x64"
        .word   0                       // res5

// ---------------------------------------------------------------------------
// UART helpers (clobber x9-x12, x16, x17; preserve x19+)
// ---------------------------------------------------------------------------
uart_putc:                              // w0 = char
        ldr     x16, =UART_BASE
1:      ldr     w17, [x16, #0x10]       // UTRSTAT
        tbz     w17, #1, 1b             // wait TX buffer empty
        str     w0, [x16, #0x20]        // UTXH
        ret

uart_puts:                              // x0 = NUL-terminated string
        stp     x29, x30, [sp, #-16]!
        mov     x12, x0
1:      ldrb    w0, [x12], #1
        cbz     w0, 2f
        bl      uart_putc
        b       1b
2:      ldp     x29, x30, [sp], #16
        ret

uart_hex64:                             // x0 = value, prints 16 hex digits
        stp     x29, x30, [sp, #-16]!
        mov     x9, x0
        mov     x10, #60
1:      lsr     x11, x9, x10
        and     x11, x11, #15
        cmp     x11, #10
        b.lt    2f
        add     x11, x11, #('a' - 10 - '0')
2:      add     w0, w11, #'0'
        bl      uart_putc
        subs    x10, x10, #4
        b.ge    1b
        ldp     x29, x30, [sp], #16
        ret

uart_dec:                               // x0 = value
        stp     x29, x30, [sp, #-16]!
        sub     sp, sp, #32
        add     x9, sp, #31
        strb    wzr, [x9]
        mov     x10, #10
1:      udiv    x11, x0, x10
        msub    x12, x11, x10, x0
        add     w12, w12, #'0'
        strb    w12, [x9, #-1]!
        mov     x0, x11
        cbnz    x0, 1b
        mov     x0, x9
        bl      uart_puts
        add     sp, sp, #32
        ldp     x29, x30, [sp], #16
        ret

.macro PUTS str
        adr     x0, \str
        bl      uart_puts
.endm

// ---------------------------------------------------------------------------
// fdt_find: x0 = fdt, x1 = node name (exact, NULL = root), x2 = property name
// returns x0 = pointer to property data (0 if none), x1 = length
// ---------------------------------------------------------------------------
fdt_find:
        mov     x15, x30
        ldr     w3, [x0, #8]            // off_dt_struct
        rev     w3, w3
        add     x3, x0, x3
        ldr     w4, [x0, #12]           // off_dt_strings
        rev     w4, w4
        add     x4, x0, x4
        mov     x5, x3                  // cursor
        mov     x6, #0                  // depth
        mov     x7, #0                  // depth of the matched node (0 = none)
.Lff_loop:
        ldr     w8, [x5], #4
        rev     w8, w8
        cmp     w8, #1
        b.eq    .Lff_begin
        cmp     w8, #2
        b.eq    .Lff_end
        cmp     w8, #3
        b.eq    .Lff_prop
        cmp     w8, #4
        b.eq    .Lff_loop
        mov     x0, #0
        mov     x1, #0
        mov     x30, x15
        ret
.Lff_begin:
        add     x6, x6, #1
        mov     x9, x5                  // node name
        mov     x10, x5
1:      ldrb    w11, [x10], #1
        cbnz    w11, 1b
        mov     x5, x10
        add     x5, x5, #3
        and     x5, x5, #-4
        cbnz    x7, .Lff_loop
        cbz     x1, .Lff_root
        mov     x10, x1
2:      ldrb    w11, [x9], #1
        ldrb    w12, [x10], #1
        cmp     w11, w12
        b.ne    .Lff_loop
        cbnz    w11, 2b
        mov     x7, x6
        b       .Lff_loop
.Lff_root:
        ldrb    w11, [x9]
        cbnz    w11, .Lff_loop
        cmp     x6, #1
        b.ne    .Lff_loop
        mov     x7, x6
        b       .Lff_loop
.Lff_end:
        cmp     x7, x6
        b.ne    1f
        mov     x7, #0
1:      sub     x6, x6, #1
        b       .Lff_loop
.Lff_prop:
        ldr     w9, [x5], #4            // len
        rev     w9, w9
        ldr     w10, [x5], #4           // nameoff
        rev     w10, w10
        mov     x11, x5                 // data
        add     x5, x5, x9
        add     x5, x5, #3
        and     x5, x5, #-4
        cbz     x7, .Lff_loop
        cmp     x7, x6
        b.ne    .Lff_loop
        add     x12, x4, x10
        mov     x13, x2
1:      ldrb    w14, [x12], #1
        ldrb    w16, [x13], #1
        cmp     w14, w16
        b.ne    .Lff_loop
        cbnz    w14, 1b
        mov     x0, x11
        mov     x1, x9
        mov     x30, x15
        ret

// ---------------------------------------------------------------------------
// Primary CPU
// ---------------------------------------------------------------------------
start:
        mov     x19, x0                 // FDT pointer from the loader
        mrs     x1, CurrentEL
        cmp     x1, #8
        b.ne    1f
        // Entered at EL2 (real M1 through m1n1; coolvm --el2): drop to EL1h like the kernel will.
        mov     x1, #(1 << 31)          // HCR_EL2.RW: EL1 is AArch64 (E2H/TGE clear, nVHE-style)
        msr     hcr_el2, x1
        mov     x1, #0x30d00000
        movk    x1, #0x0800
        msr     sctlr_el1, x1           // MMU off
        mov     x1, #(3 << 20)
        msr     cpacr_el1, x1
        mrs     x1, mpidr_el1
        msr     vmpidr_el2, x1
        mov     x1, #3
        msr     cnthctl_el2, x1         // EL1/EL0 may use the physical counter and timer
        msr     cntvoff_el2, xzr
        mov     x1, #0x3c5              // EL1h, DAIF masked
        msr     spsr_el2, x1
        adr     x1, 1f
        msr     elr_el2, x1
        isb
        eret
1:
        adr     x1, stack0_top
        mov     sp, x1
        adr     x1, vectors
        msr     vbar_el1, x1
        isb

        PUTS    s_hello
        mrs     x0, mpidr_el1
        mov     x20, x0
        PUTS    s_mpidr
        mov     x0, x20
        bl      uart_hex64
        PUTS    s_nl

        PUTS    s_fdt
        mov     x0, x19
        bl      uart_hex64
        PUTS    s_nl

        // root compatible (first string)
        mov     x0, x19
        mov     x1, #0
        adr     x2, s_p_compatible
        bl      fdt_find
        cbz     x0, 1f
        mov     x21, x0
        PUTS    s_compat
        mov     x0, x21
        bl      uart_puts
        PUTS    s_nl
        b       2f
1:      PUTS    s_nocompat
2:
        // memory@800000000 reg = <hi lo hi lo>
        mov     x0, x19
        adr     x1, s_n_memory
        adr     x2, s_p_reg
        bl      fdt_find
        cbz     x0, 1f
        ldr     w1, [x0]
        rev     w1, w1
        ldr     w2, [x0, #4]
        rev     w2, w2
        orr     x21, x2, x1, lsl #32    // base
        ldr     w1, [x0, #8]
        rev     w1, w1
        ldr     w2, [x0, #12]
        rev     w2, w2
        orr     x22, x2, x1, lsl #32    // size
        PUTS    s_membase
        mov     x0, x21
        bl      uart_hex64
        PUTS    s_memsize
        mov     x0, x22
        bl      uart_hex64
        PUTS    s_nl
        b       2f
1:      PUTS    s_nomem
2:
        // AIC identification
        ldr     x23, =AIC_BASE
        add     x26, x23, #0x4000       // SW_SET bank base
        ldr     x27, =100000            // poll bound
        ldr     w0, [x23, #0x4]         // INFO
        and     x21, x0, #0xffff
        ldr     w22, [x23, #0x2000]     // WHOAMI
        PUTS    s_aicinfo
        mov     x0, x21
        bl      uart_dec
        PUTS    s_whoami
        mov     x0, x22
        bl      uart_dec
        PUTS    s_nl

        // unknown IMP-DEF sysreg must UNDEF
        adr     x1, expect_undef
        mov     w2, #1
        str     w2, [x1]
        mrs     x5, S3_5_C15_C9_6
        adr     x1, undef_count
        ldr     w2, [x1]
        cbz     w2, 1f
        PUTS    s_undef_ok
        b       2f
1:      PUTS    s_undef_bad
        b       fail
2:      adr     x1, expect_undef
        str     wzr, [x1]

        // unknown HVC: SMCCC-style "not supported" (-1), execution continues after the hvc.
        // (At EL2 an HVC is taken by the guest itself, so this only applies to EL1 guests.)
        mrs     x1, CurrentEL
        cmp     x1, #8
        b.eq    .Lskip_hvc
        mov     x0, #0x1234
        hvc     #0x77
        cmn     x0, #1
        b.eq    1f
        PUTS    s_hvc_bad
        b       fail
1:      PUTS    s_hvc_ok
.Lskip_hvc:

        // ---- AIC hardware-IRQ path: software-trigger hwirq 100 ----
        msr     daifclr, #2             // unmask IRQ
        mov     w1, #(1 << (TEST_IRQ % 32))
        str     w1, [x26, #(0x180 + (TEST_IRQ / 32) * 4)]   // MASK_CLR
        str     w1, [x26, #((TEST_IRQ / 32) * 4)]   // SW_SET -> IRQ line
        mov     x24, #0
1:      adr     x1, irq_seen
        ldr     w0, [x1]
        cbnz    w0, 2f
        wfi
        add     x24, x24, #1
        cmp     x24, #1000
        b.lt    1b
        PUTS    s_irq_bad
        b       fail
2:      // ---- UART TX-threshold interrupt (AIC hwirq 605) ----
        mov     w1, #(1 << (UART_IRQ % 32))
        str     w1, [x26, #(0x180 + (UART_IRQ / 32) * 4)]   // unmask 605
        ldr     x25, =UART_BASE
        mov     w1, #((1 << 13) | (1 << 2))   // UCON: TXTHRESH_ENA + TX interrupt mode
        str     w1, [x25, #0x4]
        mov     x24, #0
1:      adr     x1, uirq_seen
        ldr     w0, [x1]
        cbnz    w0, 2f
        wfi
        add     x24, x24, #1
        cmp     x24, #1000
        b.lt    1b
        PUTS    s_uirq_bad
        b       fail
2:
        // ---- UART RX (only if the host fed coolvm's stdin) ----
        ldr     x25, =UART_BASE
        mov     x24, #0
1:      ldr     w0, [x25, #0x10]        // UTRSTAT
        tbnz    w0, #0, 2f              // RXD
        add     x24, x24, #1
        cmp     x24, #2000
        b.lt    1b
        PUTS    s_rx_none
        b       3f
2:      ldr     w21, [x25, #0x24]       // URXH
        PUTS    s_rx
        mov     w0, w21
        bl      uart_putc
        PUTS    s_nl
3:
        // ---- virtual timer as FIQ ----
        mrs     x20, cntfrq_el0
        PUTS    s_freq
        mov     x0, x20
        bl      uart_dec
        PUTS    s_nl
        mov     x1, #100
        udiv    x1, x20, x1             // 10 ms
        adr     x2, tick_reload
        str     x1, [x2]
        msr     cntv_tval_el0, x1
        mov     x1, #1
        msr     cntv_ctl_el0, x1        // ENABLE
        isb
        msr     daifclr, #1             // unmask FIQ
        mov     x24, #0
1:      adr     x1, tick_count
        ldr     w0, [x1]
        cmp     w0, #5
        b.ge    2f
        wfi
        add     x24, x24, #1
        cmp     x24, x27
        b.lt    1b
        PUTS    s_tick_bad
        b       fail
2:      // report the ticks recorded by the FIQ handler
        mov     x24, #0                 // index
        adr     x25, tick_ts
1:      PUTS    s_tick
        add     x0, x24, #1
        bl      uart_dec
        PUTS    s_nl
        cbz     x24, 2f
        add     x1, x25, x24, lsl #3
        ldr     x2, [x1]
        ldr     x3, [x1, #-8]
        sub     x2, x2, x3
        ldr     x3, =1000000
        mul     x2, x2, x3
        udiv    x2, x2, x20             // microseconds (x20 = cntfrq)
        PUTS    s_tickdt
        mov     x0, x2
        bl      uart_dec
        PUTS    s_us
2:      add     x24, x24, #1
        cmp     x24, #5
        b.lt    1b
        // Rearm to a different deadline that is already expired. This models a
        // host missing the entire quiet interval between rapid guest ticks.
        // The timer condition never deasserts: CVAL progress must rearm HVF.
        msr     daifset, #1
        adr     x1, tick_count
        str     wzr, [x1]
        adr     x1, tick_reload
        mov     x2, #-1
        str     x2, [x1]
        msr     cntv_tval_el0, x2
        mov     x1, #1
        msr     cntv_ctl_el0, x1
        isb
        msr     daifclr, #1
1:      adr     x1, tick_count
        ldr     w0, [x1]
        cmp     w0, #5
        b.ge    2f
        wfi
        b       1b
2:      PUTS    s_tick_rearm
        // ---- SMP: start cpu@1 through its spin-table release address ----
        mov     x0, x19
        adr     x1, s_n_cpu1
        adr     x2, s_p_reladdr
        bl      fdt_find
        cbnz    x0, 1f
        PUTS    s_norel
        b       fail
1:      ldr     w1, [x0]                // cpu-release-addr = two big-endian cells; property data is only
        rev     w1, w1                  // 4-byte aligned, and with the MMU off an 8-byte load would fault
        ldr     w2, [x0, #4]
        rev     w2, w2
        orr     x21, x2, x1, lsl #32
        PUTS    s_reladdr
        mov     x0, x21
        bl      uart_hex64
        PUTS    s_nl
        adr     x3, secondary_entry
        str     x3, [x21]
        dsb     sy
        sev
        mov     x24, #0
1:      adr     x1, cpu1_up
        ldr     w0, [x1]
        cbnz    w0, 2f
        wfe
        add     x24, x24, #1
        cmp     x24, x27
        b.lt    1b
        PUTS    s_smp_bad
        b       fail
2:      PUTS    s_ipi_send
        mov     x0, #1                  // aff0 of cpu1 (same cluster)
        msr     S3_5_C15_C0_0, x0       // IPI_RR_LOCAL_EL1
        isb
        mov     x24, #0
1:      adr     x1, cpu1_done
        ldr     w0, [x1]
        cbnz    w0, 2f
        wfe
        add     x24, x24, #1
        cmp     x24, x27
        b.lt    1b
        PUTS    s_ipi_bad
        b       fail
2:      PUTS    s_smp_ok
        PUTS    s_pass
        mrs     x1, CurrentEL
        cmp     x1, #8
        b.eq    .Lpoweroff_mmio
        ldr     x0, =0x84000008         // EL1: PSCI SYSTEM_OFF (VM-only hypercall)
        hvc     #0
        b       .
.Lpoweroff_mmio:                        // EL2: VM-only finisher device, found through the DT
        mov     x0, x19
        adr     x1, s_n_finisher
        adr     x2, s_p_reg
        bl      fdt_find
        cbz     x0, fail
        ldr     w1, [x0]
        rev     w1, w1
        ldr     w2, [x0, #4]
        rev     w2, w2
        orr     x1, x2, x1, lsl #32
        mov     w2, #0x5555
        str     w2, [x1]
        b       .

fail:
        PUTS    s_fail
        mov     x0, #1
        mrs     x1, CurrentEL
        cmp     x1, #8
        b.eq    1f
        hvc     #0xC001                 // coolvm exit(1)
        b       .
1:      ldr     x1, =0x1ff000000        // finisher: exit(1)
        ldr     w2, =0x13333
        str     w2, [x1]
        b       .

// ---------------------------------------------------------------------------
// Secondary CPU (entered from the spin table: EL1h, MMU off, x0 = 0)
// ---------------------------------------------------------------------------
secondary_entry:
        adr     x1, stack1_top
        mov     sp, x1
        adr     x1, vectors
        msr     vbar_el1, x1
        isb
        PUTS    s_hello1
        mrs     x0, mpidr_el1
        bl      uart_hex64
        PUTS    s_nl
        msr     daifclr, #3
        adr     x1, cpu1_up
        mov     w2, #1
        str     w2, [x1]
        dsb     sy
        sev
1:      adr     x1, ipi_count
        ldr     w0, [x1]
        cbnz    w0, 2f
        wfi
        b       1b
2:      PUTS    s_gotipi
        adr     x1, cpu1_done
        mov     w2, #1
        str     w2, [x1]
        dsb     sy
        sev
3:      wfi
        b       3b

// ---------------------------------------------------------------------------
// Exception vectors (VBAR_EL1)
// ---------------------------------------------------------------------------
        .balign 2048
vectors:
        .rept   4                       // current EL, SP0
        .balign 128
        b       bad_exc
        .endr
        .balign 128                     // current EL, SPx: sync
        b       sync_handler
        .balign 128                     // IRQ
        b       irq_handler
        .balign 128                     // FIQ
        b       fiq_handler
        .balign 128                     // SError
        b       bad_exc
        .rept   8                       // lower EL
        .balign 128
        b       bad_exc
        .endr

bad_exc:
        mrs     x19, esr_el1
        mrs     x20, elr_el1
        mrs     x21, far_el1
        PUTS    s_badexc
        mov     x0, x19
        bl      uart_hex64
        PUTS    s_elr
        mov     x0, x20
        bl      uart_hex64
        PUTS    s_far
        mov     x0, x21
        bl      uart_hex64
        PUTS    s_nl
        b       fail

sync_handler:                           // only the expected UNDEF is tolerated
        mrs     x0, esr_el1
        lsr     x1, x0, #26
        cbnz    x1, bad_exc
        adr     x1, expect_undef
        ldr     w2, [x1]
        cbz     w2, bad_exc
        adr     x1, undef_count
        ldr     w2, [x1]
        add     w2, w2, #1
        str     w2, [x1]
        mrs     x1, elr_el1
        add     x1, x1, #4
        msr     elr_el1, x1
        eret

.macro SAVE
        sub     sp, sp, #(16 * 10)
        stp     x0, x1, [sp, #0]
        stp     x2, x3, [sp, #16]
        stp     x4, x5, [sp, #32]
        stp     x6, x7, [sp, #48]
        stp     x8, x9, [sp, #64]
        stp     x10, x11, [sp, #80]
        stp     x12, x13, [sp, #96]
        stp     x14, x15, [sp, #112]
        stp     x16, x17, [sp, #128]
        stp     x29, x30, [sp, #144]
.endm
.macro RESTORE
        ldp     x0, x1, [sp, #0]
        ldp     x2, x3, [sp, #16]
        ldp     x4, x5, [sp, #32]
        ldp     x6, x7, [sp, #48]
        ldp     x8, x9, [sp, #64]
        ldp     x10, x11, [sp, #80]
        ldp     x12, x13, [sp, #96]
        ldp     x14, x15, [sp, #112]
        ldp     x16, x17, [sp, #128]
        ldp     x29, x30, [sp, #144]
        add     sp, sp, #(16 * 10)
.endm

irq_handler:                            // AIC IRQ: read EVENT (acks + auto-masks), handle, EOI
        SAVE
        ldr     x9, =AIC_BASE
        add     x13, x9, #0x4000
        ldr     w10, [x9, #0x2004]      // EVENT
        lsr     w11, w10, #16
        and     w11, w11, #0xff         // type
        and     w12, w10, #0xffff       // num
        cmp     w11, #1                 // AIC_EVENT_TYPE_IRQ
        b.ne    .Lirq_other
        cmp     w12, #TEST_IRQ
        b.ne    1f
        PUTS    s_irq_taken
        mov     x0, x10
        bl      uart_hex64
        PUTS    s_nl
        mov     w1, #(1 << (TEST_IRQ % 32))
        str     w1, [x13, #(0x80 + (TEST_IRQ / 32) * 4)]    // SW_CLR
        str     w1, [x13, #(0x180 + (TEST_IRQ / 32) * 4)]    // MASK_CLR (eoi)
        adr     x1, irq_seen
        mov     w2, #1
        str     w2, [x1]
        b       .Lirq_out
1:      cmp     w12, #UART_IRQ
        b.ne    .Lirq_other
        ldr     x1, =UART_BASE
        str     wzr, [x1, #0x4]         // UCON: disable TX threshold (level source)
        PUTS    s_uirq_taken
        adr     x1, uirq_seen
        mov     w2, #1
        str     w2, [x1]
        b       .Lirq_out
.Lirq_other:
        PUTS    s_irq_spur
        mov     x0, x10
        bl      uart_hex64
        PUTS    s_nl
.Lirq_out:
        RESTORE
        eret

fiq_handler:                            // aic_handle_fiq(): IPI_SR first, then timers
        SAVE
        mrs     x0, S3_5_C15_C1_1       // IPI_SR_EL1
        tbz     x0, #0, 1f
        mov     x0, #1
        msr     S3_5_C15_C1_1, x0       // ack
        isb
        adr     x1, ipi_count
        ldr     w2, [x1]
        add     w2, w2, #1
        str     w2, [x1]
1:      mrs     x0, cntv_ctl_el0
        and     x0, x0, #7
        cmp     x0, #5                  // ENABLE | ISTATUS, not masked
        b.ne    .Lfiq_out
        mrs     x3, cntvct_el0          // timestamp of this tick
        adr     x1, tick_count
        ldr     w2, [x1]
        add     w2, w2, #1
        str     w2, [x1]
        cmp     w2, #5
        b.lt    2f
        msr     cntv_ctl_el0, xzr       // done: disable the timer
        b       3f
2:      mrs     x0, cntv_cval_el0       // re-arm at an absolute deadline (no drift)
        adr     x1, tick_reload
        ldr     x4, [x1]
        add     x0, x0, x4
        msr     cntv_cval_el0, x0       // condition deasserts
3:      adr     x1, tick_ts             // record the timestamp; printing happens outside the handler
        sub     w4, w2, #1
        add     x1, x1, x4, lsl #3
        str     x3, [x1]
.Lfiq_out:
        isb
        RESTORE
        eret

// ---------------------------------------------------------------------------
        .balign 8
expect_undef:   .word 0
undef_count:    .word 0
irq_seen:       .word 0
uirq_seen:      .word 0
tick_count:     .word 0
cpu1_up:        .word 0
cpu1_done:      .word 0
ipi_count:      .word 0
tick_reload:    .quad 0
tick_ts:        .skip 8 * 8

s_hello:        .asciz "hello from coolvm\n"
s_mpidr:        .asciz "cpu0 mpidr=0x"
s_fdt:          .asciz "fdt at 0x"
s_compat:       .asciz "dt compatible: "
s_nocompat:     .asciz "dt compatible: NOT FOUND\n"
s_membase:      .asciz "dt memory base=0x"
s_memsize:      .asciz " size=0x"
s_nomem:        .asciz "dt memory: NOT FOUND\n"
s_aicinfo:      .asciz "aic: nr_irq="
s_whoami:       .asciz " whoami="
s_undef_ok:     .asciz "unknown sysreg -> UNDEF ok\n"
s_undef_bad:    .asciz "unknown sysreg did not UNDEF\n"
s_irq_taken:    .asciz "aic irq taken, event=0x"
s_irq_bad:      .asciz "aic irq NOT taken\n"
s_uirq_taken:   .asciz "uart tx-threshold irq taken (hwirq 605)\n"
s_uirq_bad:     .asciz "uart irq NOT taken\n"
s_irq_spur:     .asciz "spurious irq event=0x"
s_hvc_ok:       .asciz "unknown hvc returns -1 ok\n"
s_hvc_bad:      .asciz "unknown hvc did not return -1\n"
s_rx_none:      .asciz "uart rx: none\n"
s_rx:           .asciz "uart rx: "
s_freq:         .asciz "timer: cntfrq="
s_tick:         .asciz "tick "
s_tickdt:       .asciz "  period "
s_us:           .asciz " us\n"
s_tick_rearm:   .asciz "expired timer rearm ok\n"
s_tick_bad:     .asciz "timer FIQ NOT taken\n"
s_reladdr:      .asciz "smp: cpu1 cpu-release-addr=0x"
s_norel:        .asciz "smp: cpu@1 cpu-release-addr NOT FOUND\n"
s_smp_bad:      .asciz "smp: cpu1 did not come up\n"
s_hello1:       .asciz "hello from cpu1 mpidr=0x"
s_ipi_send:     .asciz "smp: sending fast IPI to cpu1\n"
s_gotipi:       .asciz "cpu1: got fast IPI (FIQ)\n"
s_ipi_bad:      .asciz "smp: IPI not received\n"
s_smp_ok:       .asciz "smp ok\n"
s_pass:         .asciz "coolvm-test PASS, powering off\n"
s_fail:         .asciz "coolvm-test FAIL\n"
s_badexc:       .asciz "!! unexpected exception ESR=0x"
s_elr:          .asciz " ELR=0x"
s_far:          .asciz " FAR=0x"
s_nl:           .asciz "\n"

s_p_compatible: .asciz "compatible"
s_p_reg:        .asciz "reg"
s_p_reladdr:    .asciz "cpu-release-addr"
s_n_memory:     .asciz "memory@800000000"
s_n_cpu1:       .asciz "cpu@1"
s_n_finisher:   .asciz "finisher@1ff000000"

        .ltorg
        .balign 16
        .skip   0x2000
stack0_top:
        .skip   0x2000
stack1_top:
        .balign 16
image_end:
