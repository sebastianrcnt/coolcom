// Native AArch64 exception context. Layout follows Aiwnios
// asm/exceptAARCH64.s (nrootconauto, BSD-3), commit e155e87.
.text
.p2align 2
.globl _AIWNIOS_SetJmp
_AIWNIOS_SetJmp:
    str x19, [x0, #8]
    str x20, [x0, #16]
    str x21, [x0, #24]
    str x22, [x0, #32]
    str x23, [x0, #40]
    str x24, [x0, #48]
    str x25, [x0, #56]
    str x26, [x0, #64]
    str x27, [x0, #72]
    str x29, [x0, #88]
    str x30, [x0, #96]
    str d8, [x0, #104]
    str d9, [x0, #112]
    str d10, [x0, #120]
    str d11, [x0, #128]
    str d12, [x0, #136]
    str d13, [x0, #144]
    str d14, [x0, #152]
    str d15, [x0, #160]
    mov x1, sp
    str x1, [x0, #168]
    mov x0, #0
    ret

.p2align 2
.globl _AIWNIOS_LongJmp
_AIWNIOS_LongJmp:
    ldr x19, [x0, #8]
    ldr x20, [x0, #16]
    ldr x21, [x0, #24]
    ldr x22, [x0, #32]
    ldr x23, [x0, #40]
    ldr x24, [x0, #48]
    ldr x25, [x0, #56]
    ldr x26, [x0, #64]
    ldr x27, [x0, #72]
    ldr x29, [x0, #88]
    ldr x30, [x0, #96]
    ldr d8, [x0, #104]
    ldr d9, [x0, #112]
    ldr d10, [x0, #120]
    ldr d11, [x0, #128]
    ldr d12, [x0, #136]
    ldr d13, [x0, #144]
    ldr d14, [x0, #152]
    ldr d15, [x0, #160]
    ldr x1, [x0, #168]
    mov sp, x1
    mov x0, #1
    ret
