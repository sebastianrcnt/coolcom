// macOS SysV <-> Aiwnios HolyC stack ABI, with GS base transitions.
.text
.p2align 4
.globl _NativeX86Call
_NativeX86Call:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rdi, %r12
    movq %rsi, %r13
    movq %rdx, %r14
    movq _NativeCoolGS(%rip), %rdi
    movq $0x3000003, %rax
    syscall
    movq %r13, %rcx
1:  testq %rcx, %rcx
    jz 2f
    decq %rcx
    pushq (%r14,%rcx,8)
    jmp 1b
2:  callq *%r12
    movq %rax, %r12
    movq _NativeHostGS(%rip), %rdi
    movq $0x3000003, %rax
    syscall
    movq %r12, %rax
    leaq -40(%rbp), %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    retq

.p2align 4
.globl _NativeX86Bridge
_NativeX86Bridge:
    pushq %rbp
    movq %rsp, %rbp
    pushq %rsi
    pushq %rdi
    pushq %r10
    pushq %r11
    andq $-16, %rsp
    subq $176, %rsp
    movq %rax, 160(%rsp)
    movdqu %xmm6, 0(%rsp)
    movdqu %xmm7, 16(%rsp)
    movdqu %xmm8, 32(%rsp)
    movdqu %xmm9, 48(%rsp)
    movdqu %xmm10, 64(%rsp)
    movdqu %xmm11, 80(%rsp)
    movdqu %xmm12, 96(%rsp)
    movdqu %xmm13, 112(%rsp)
    movdqu %xmm14, 128(%rsp)
    movdqu %xmm15, 144(%rsp)
    movq _NativeHostGS(%rip), %rdi
    movq $0x3000003, %rax
    syscall
    movq 160(%rsp), %rdi
    leaq 24(%rbp), %rsi
    callq _NativeX86Dispatch
    movq %rax, 168(%rsp)
    movq _NativeCoolGS(%rip), %rdi
    movq $0x3000003, %rax
    syscall
    movq 168(%rsp), %rax
    movdqu 0(%rsp), %xmm6
    movdqu 16(%rsp), %xmm7
    movdqu 32(%rsp), %xmm8
    movdqu 48(%rsp), %xmm9
    movdqu 64(%rsp), %xmm10
    movdqu 80(%rsp), %xmm11
    movdqu 96(%rsp), %xmm12
    movdqu 112(%rsp), %xmm13
    movdqu 128(%rsp), %xmm14
    movdqu 144(%rsp), %xmm15
    leaq -32(%rbp), %rsp
    popq %r11
    popq %r10
    popq %rdi
    popq %rsi
    popq %rbp
    retq

// Exception buffer uses the same reserved 192-byte storage as the ARM host.
.p2align 4
.globl _AIWNIOS_SetJmp
_AIWNIOS_SetJmp:
    movq 8(%rsp), %rax
    movq (%rsp), %rcx
    movq %rcx, 0(%rax)
    leaq 16(%rsp), %rcx
    movq %rcx, 8(%rax)
    movq %rbp, 16(%rax)
    movq %rbx, 24(%rax)
    movq %rsi, 32(%rax)
    movq %rdi, 40(%rax)
    movq %r10, 48(%rax)
    movq %r11, 56(%rax)
    movq %r12, 64(%rax)
    movq %r13, 72(%rax)
    movq %r14, 80(%rax)
    movq %r15, 88(%rax)
    movsd %xmm6, 96(%rax)
    movsd %xmm7, 104(%rax)
    movsd %xmm8, 112(%rax)
    movsd %xmm9, 120(%rax)
    movsd %xmm10, 128(%rax)
    movsd %xmm11, 136(%rax)
    movsd %xmm12, 144(%rax)
    movsd %xmm13, 152(%rax)
    movsd %xmm14, 160(%rax)
    movsd %xmm15, 168(%rax)
    xorq %rax, %rax
    retq $8
.p2align 4
.globl _AIWNIOS_LongJmp
_AIWNIOS_LongJmp:
    movq 8(%rsp), %rax
    movq 0(%rax), %rdx
    movq 8(%rax), %rsp
    movq 16(%rax), %rbp
    movq 24(%rax), %rbx
    movq 32(%rax), %rsi
    movq 40(%rax), %rdi
    movq 48(%rax), %r10
    movq 56(%rax), %r11
    movq 64(%rax), %r12
    movq 72(%rax), %r13
    movq 80(%rax), %r14
    movq 88(%rax), %r15
    movsd 96(%rax), %xmm6
    movsd 104(%rax), %xmm7
    movsd 112(%rax), %xmm8
    movsd 120(%rax), %xmm9
    movsd 128(%rax), %xmm10
    movsd 136(%rax), %xmm11
    movsd 144(%rax), %xmm12
    movsd 152(%rax), %xmm13
    movsd 160(%rax), %xmm14
    movsd 168(%rax), %xmm15
    movq $1, %rax
    jmpq *%rdx
