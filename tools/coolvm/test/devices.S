// Device smoke test. All MMIO is single-register ldr/str.
        .equ UART, 0x235200000
        .equ FB, 0x900000000
        .equ INPUT, 0x1ff001000
        .equ BLK, 0x1ff010000
        .equ AIC, 0x23b100000
        .section .text
        .globl _start
_start:
        b start
        .word 0
        .quad 0
        .quad image_end - _start
        .quad 0xa
        .quad 0,0,0
        .word 0x644d5241
        .word 0
start:
        adr x0, stack_end
        mov sp, x0
        ldr x20, =FB
        mov w0, #0xff0000
        str w0, [x20]             // red top-left
        mov w0, #0xff00
        str w0, [x20,#4]          // green next pixel
        ldr x20, =INPUT
        ldr w0, [x20]
        cmp w0, #2
        b.lt fail
        ldr x21, =AIC
        add x22, x21, #0x4000
        mov w0, #1
        lsl w0, w0, #28           // IRQ 700, word 21
        str w0, [x22, #0x1d4]    // AIC MASK_CLR + 21*4
        ldr w0, [x21, #0x2004]   // AIC EVENT auto-masks IRQ
        ldr w1, =0x102bc
        cmp w0, w1
        b.ne fail
        ldr w0, [x20,#4]          // key type
        cmp w0, #1
        b.ne fail
        ldr w0, [x20,#4]          // KEY_A = 30
        cmp w0, #30
        b.ne fail
        ldr w0, [x20,#4]          // pressed
        cmp w0, #1
        b.ne fail
        ldr w0, [x20,#4]          // relative mouse type
        cmp w0, #2
        b.ne fail
        ldr w0, [x20,#4]          // REL_X
        cbnz w0, fail
        ldr w0, [x20,#4]
        cmp w0, #7
        b.ne fail
        adr x0, s_input
        bl puts

        ldr x20, =BLK
        ldr w0, [x20]
        ldr w1, =0x74726976
        cmp w0, w1
        b.ne fail
        ldr w0, [x20,#4]
        cmp w0, #2
        b.ne fail
        ldr w0, [x20,#8]
        cmp w0, #2
        b.ne fail
        // Negotiate VERSION_1 and FLUSH.
        mov w0, #0
        str w0, [x20,#0x14]
        ldr w1, [x20,#0x10]
        tbz w1,#9,fail
        str w0, [x20,#0x24]
        mov w0, #(1<<9)
        str w0, [x20,#0x20]
        mov w0,#1
        str w0, [x20,#0x14]
        ldr w1, [x20,#0x10]
        tbz w1,#0,fail
        str w0, [x20,#0x24]
        str w0, [x20,#0x20]
        mov w0,#11
        str w0, [x20,#0x70]       // ACK|DRIVER|FEATURES_OK
        mov w0,#0
        str w0, [x20,#0x30]
        mov w0,#8
        str w0, [x20,#0x38]
        adr x1, desc
        str w1, [x20,#0x80]
        lsr x1,x1,#32
        str w1, [x20,#0x84]
        adr x1, avail
        str w1, [x20,#0x90]
        lsr x1,x1,#32
        str w1, [x20,#0x94]
        adr x1, used
        str w1, [x20,#0xa0]
        lsr x1,x1,#32
        str w1, [x20,#0xa4]
        mov w0,#1
        str w0, [x20,#0x44]
        mov w0,#15
        str w0, [x20,#0x70]       // DRIVER_OK

        // READ sector 0 into readbuf.
        adr x0, hdr
        str wzr,[x0]
        str xzr,[x0,#8]
        adr x0, readbuf
        mov w1,#3                // descriptor 1: WRITE|NEXT
        bl setup_chain
        adr x1, avail
        mov w0,#1
        strh w0,[x1,#2]
        mov w0,#0
        str w0,[x20,#0x50]
        adr x1, used
1:      ldrh w0,[x1,#2]
        cbz w0,1b
        adr x1, statusbyte
        ldrb w0,[x1]
        cbnz w0,fail
        ldr w0,[x20,#0x60]       // used-ring interrupt
        cmp w0,#1
        b.ne fail
        str w0,[x20,#0x64]       // acknowledge
        adr x1, readbuf
        ldr w0,[x1]
        ldr w1, =0x44434241     // ABCD
        cmp w0,w1
        b.ne fail
        adr x0,s_read
        bl puts

        // WRITE sector 1, then FLUSH.
        adr x1,hdr
        mov w0,#1
        str w0,[x1]
        mov x0,#1
        str x0,[x1,#8]
        adr x0,writebuf
        mov w1,#1                // descriptor 1: NEXT, readable
        bl setup_chain
        adr x1,statusbyte
        mov w0,#0xff
        strb w0,[x1]
        adr x1,avail
        mov w0,#2
        strh w0,[x1,#2]
        mov w0,#0
        str w0,[x20,#0x50]
        adr x1,used
2:      ldrh w0,[x1,#2]
        cmp w0,#2
        b.ne 2b
        adr x1,statusbyte
        ldrb w0,[x1]
        cbnz w0,fail
        adr x0,s_write
        bl puts

        // FLUSH header -> status (descriptor 0 jumps directly to 2).
        adr x1,hdr
        mov w0,#4
        str w0,[x1]
        adr x1,desc
        mov w0,#2
        strh w0,[x1,#14]
        adr x1,statusbyte
        mov w0,#0xff
        strb w0,[x1]
        adr x1,avail
        mov w0,#3
        strh w0,[x1,#2]
        mov w0,#0
        str w0,[x20,#0x50]
        adr x1,used
3:      ldrh w0,[x1,#2]
        cmp w0,#3
        b.ne 3b
        adr x1,statusbyte
        ldrb w0,[x1]
        cbnz w0,fail
        adr x0,s_flush
        bl puts
        ldr x20, =(BLK + 0x1000)
        ldr w0,[x20]
        ldr w1,=0x74726976
        cmp w0,w1
        b.ne fail
        ldr w0,[x20,#0x100]     // second image capacity (8 sectors)
        cmp w0,#8
        b.ne fail
        adr x0,s_pass
        bl puts
        mov x0,#0
        hvc #0xc001
fail:   adr x0,s_fail
        bl puts
        mov x0,#1
        hvc #0xc001

// x0=data buffer, w1=descriptor 1 flags; clobbers x2-x6
setup_chain:
        adr x2,desc
        adr x3,hdr
        str x3,[x2]
        mov w3,#16
        str w3,[x2,#8]
        mov w3,#1
        strh w3,[x2,#12]        // NEXT
        mov w3,#1
        strh w3,[x2,#14]
        str x0,[x2,#16]
        mov w3,#512
        str w3,[x2,#24]
        strh w1,[x2,#28]
        mov w3,#2
        strh w3,[x2,#30]
        adr x3,statusbyte
        str x3,[x2,#32]
        mov w3,#1
        str w3,[x2,#40]
        mov w3,#2
        strh w3,[x2,#44]        // WRITE
        strh wzr,[x2,#46]
        ret
puts:   stp x29,x30,[sp,#-16]!
        mov x2,x0
        ldr x3,=UART
1:      ldrb w0,[x2],#1
        cbz w0,2f
        str w0,[x3,#0x20]
        b 1b
2:      ldp x29,x30,[sp],#16
        ret
s_input: .asciz "input key and mouse ok\n"
s_read: .asciz "disk read ok\n"
s_write: .asciz "disk write ok\n"
s_flush: .asciz "disk flush ok\n"
s_pass: .asciz "devices PASS\n"
s_fail: .asciz "devices FAIL\n"
        .balign 16
desc:   .space 128
        .balign 16
avail:  .space 32
        .balign 16
used:   .space 80
hdr:    .space 16
statusbyte: .byte 0
        .balign 16
readbuf: .space 512
writebuf: .ascii "coolvm disk write"
        .space 495
        .balign 16
stack:  .space 4096
stack_end:
image_end:
