// A new CVAL which has already expired must generate another timer FIQ.
// Reproduces a host polling gap longer than a guest timer period: ISTATUS
// never appears clear to the VMM, although the guest did reprogram CVAL.
        .section .text
        .globl _start
_start:
        b       start
        .word   0
        .quad   0
        .quad   image_end - _start
        .quad   0xa
        .quad   0, 0, 0
        .word   0x644d5241
        .word   0
start:
        adr     x0, vectors
        msr     vbar_el1, x0
        mrs     x0, cntvct_el0
        sub     x0, x0, #1024
        msr     cntv_cval_el0, x0
        mov     x0, #1
        msr     cntv_ctl_el0, x0
        isb
        msr     daifclr, #3
        b       .

        .macro VEC target
        .balign 128
        b       \target
        .endm
        .balign 2048
vectors:
        .rept 6
        VEC bad
        .endr
        VEC fiq
        .rept 9
        VEC bad
        .endr

fiq:
        mrs     x0, S3_5_C15_C1_1       // M1 FIQ entry/ack, as in the kernel
        adr     x1, ticks
        ldr     x2, [x1]
        add     x2, x2, #1
        str     x2, [x1]
        cmp     x2, #2
        b.eq    passed
        mrs     x0, cntv_cval_el0
        add     x0, x0, #1             // changed, but still expired
        msr     cntv_cval_el0, x0
        isb
        eret
passed:
        msr     cntv_ctl_el0, xzr
        adr     x0, message
        ldr     x1, =0x235200000
1:      ldrb    w2, [x0], #1
        cbz     w2, 2f
        str     w2, [x1, #0x20]
        b       1b
2:      mov     w0, #0x5555
        b       finish
bad:
        ldr     w0, =0x13333
finish:
        ldr     x1, =0x1ff000000
        str     w0, [x1]
        b       .
        .balign 8
ticks:  .quad   0
message:.asciz "timer rearm PASS\n"
        .ltorg
image_end:
