// coolvm negative test: read an MMIO address nothing is mapped at.
// Default: coolvm must stop with exit status 1 and a clear diagnostic.
// With --lenient the read returns 0 and this guest powers off through the finisher device.
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
        ldr     x2, =0x1ff000000        // VM-only finisher device
        cbnz    w0, 1f
        mov     w3, #0x5555             // power off (exit 0)
        str     w3, [x2]
        b       .
1:      ldr     w3, =0x23333            // exit(2)
        str     w3, [x2]
        b       .
        .ltorg
image_end:
