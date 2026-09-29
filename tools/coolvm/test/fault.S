// coolvm negative test: read an MMIO address nothing is mapped at.
// Default: coolvm must stop with exit status 1 and a clear diagnostic.
// With --lenient the read returns 0 and this guest exits with status 0.
        .section .text
        .globl _start
_start:
        b       start
        .word   0
        .quad   0                       // text_offset
        .quad   image_end - _start      // image_size
        .quad   0xa
        .quad   0, 0, 0
        .word   0x644d5241              // "ARM\x64"
        .word   0
start:
        ldr     x1, =0x235300000        // not a device coolvm knows
        ldr     w0, [x1]
        cbnz    w0, 1f
        mov     x0, #0
        hvc     #0xC001                 // coolvm exit(0)
1:      mov     x0, #2
        hvc     #0xC001
        b       .
        .ltorg
image_end:
