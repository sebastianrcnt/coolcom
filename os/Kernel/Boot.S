// Boot stub: bring the CPU to a sane EL1 state, then jump into HolyC KMain.
//  - drop from EL2 to EL1 if needed
//  - enable FP/SIMD (HolyC F64 code uses it)
//  - install exception vectors that dump ESR/ELR/FAR over the UART
//  - identity-map RAM + devices and turn on the MMU and caches

#define UART_BASE 0x09000000
#define RAM_END   0x80000000 // QEMU virt, 1GB at 0x40000000

// MAIR attribute indices
#define MT_DEVICE 0 // Device-nGnRE
#define MT_NORMAL 1 // Normal, write-back cacheable

// Level-1 block descriptors (1GB each, 4KB granule)
#define BLK_VALID  (1 << 0)
#define BLK_ATTR(i) ((i) << 2)
#define BLK_ISH    (3 << 8)
#define BLK_AF     (1 << 10)
#define BLK_PXN    (1 << 53)
#define BLK_UXN    (1 << 54)
#define BLK_DEVICE (BLK_VALID | BLK_ATTR(MT_DEVICE) | BLK_AF | BLK_PXN | BLK_UXN)
#define BLK_NORMAL (BLK_VALID | BLK_ATTR(MT_NORMAL) | BLK_AF | BLK_ISH)

.section .text.boot
.global _start
_start:
  mrs x0, mpidr_el1
  and x0, x0, #3
  cbnz x0, park

  mrs x0, CurrentEL
  lsr x0, x0, #2
  cmp x0, #2
  b.ne 1f
  // EL2 -> EL1: AArch64 at EL1, no traps of FP/timers, eret into EL1h.
  mov x0, #(1 << 31)
  msr hcr_el2, x0
  mov x0, #3
  msr cnthctl_el2, x0
  msr cptr_el2, xzr
  mov x0, #0x3c5 // DAIF masked, EL1h
  msr spsr_el2, x0
  adr x0, 1f
  msr elr_el2, x0
  eret
1:
  ldr x0, =stack_top
  mov sp, x0

  // FP/SIMD on at EL1 and EL0.
  mov x0, #(3 << 20)
  msr cpacr_el1, x0
  isb

  adr x0, vectors
  msr vbar_el1, x0
  isb

  // Zero .bss (holds the page table).
  ldr x0, =__bss_start
  ldr x1, =__bss_end
2:
  cmp x0, x1
  b.hs 3f
  str xzr, [x0], #8
  b 2b
3:
  bl mmu_on

  // Zero the kernel module's zero-initialized globals.
  ldr x0, =KBSS_START
  ldr x1, =KBSS_END
4:
  cmp x0, x1
  b.hs 5f
  str xzr, [x0], #8
  b 4b
5:
  // Run the module's top-level code (global initializers) in order.
  ldr x20, =MAIN_TABLE
6:
  ldr x1, [x20], #8
  cbz x1, 7f
  blr x1
  b 6b
7:
  // KMain(heap_start, heap_end): all RAM above the boot stack is free.
  ldr x0, =stack_top
  ldr x1, =RAM_END
  ldr x2, =KMAIN
  blr x2

park:
  wfe
  b park

// Identity map: [0,1GB) devices, [1GB,2GB) RAM.
mmu_on:
  adr x0, l1_table
  ldr x1, =(0x00000000 | BLK_DEVICE)
  str x1, [x0, #0]
  ldr x1, =(0x40000000 | BLK_NORMAL)
  str x1, [x0, #8]
  dsb ishst

  ldr x1, =((0x04 << (8 * MT_DEVICE)) | (0xff << (8 * MT_NORMAL)))
  msr mair_el1, x1
  // T0SZ=25 (39-bit VA, walk starts at L1), inner/outer WB WA, inner shareable,
  // 4KB granule, TTBR1 walks disabled, 40-bit PA.
  ldr x1, =((25 << 0) | (1 << 8) | (1 << 10) | (3 << 12) | (0 << 14) | (1 << 23) | (2 << 32))
  msr tcr_el1, x1
  msr ttbr0_el1, x0
  isb
  tlbi vmalle1
  dsb ish
  isb

  mrs x1, sctlr_el1
  orr x1, x1, #(1 << 0)  // M: MMU
  orr x1, x1, #(1 << 2)  // C: data cache
  orr x1, x1, #(1 << 12) // I: instruction cache
  bic x1, x1, #(1 << 1)  // A: no alignment faults
  msr sctlr_el1, x1
  isb
  ret

// Exception vectors: every entry is fatal for now, report and hang.
.macro VEC n
  .balign 0x80
  mov x19, #\n
  b except_fatal
.endm

.balign 0x800
vectors:
  VEC 0  // current EL, SP0: sync
  VEC 1  //   irq
  VEC 2  //   fiq
  VEC 3  //   serror
  VEC 4  // current EL, SPx: sync
  VEC 5  //   irq
  VEC 6  //   fiq
  VEC 7  //   serror
  VEC 8  // lower EL, AArch64
  VEC 9
  VEC 10
  VEC 11
  VEC 12 // lower EL, AArch32
  VEC 13
  VEC 14
  VEC 15

except_fatal:
  adr x0, str_exc
  bl uart_puts
  mov x0, x19
  bl uart_hex
  adr x0, str_esr
  bl uart_puts
  mrs x0, esr_el1
  bl uart_hex
  adr x0, str_elr
  bl uart_puts
  mrs x0, elr_el1
  bl uart_hex
  adr x0, str_far
  bl uart_puts
  mrs x0, far_el1
  bl uart_hex
  adr x0, str_nl
  bl uart_puts
  b park

// uart_puts(x0 = NUL-terminated string). Clobbers x0-x2.
uart_puts:
  ldr x1, =UART_BASE
1:
  ldrb w2, [x0], #1
  cbz w2, 2f
  strb w2, [x1]
  b 1b
2:
  ret

// uart_hex(x0): print as 16 hex digits. Clobbers x0-x4.
uart_hex:
  ldr x1, =UART_BASE
  mov x3, #60
1:
  lsr x2, x0, x3
  and x2, x2, #0xf
  cmp x2, #10
  add x4, x2, #'0'
  add x2, x2, #('A' - 10)
  csel x2, x4, x2, lo
  strb w2, [x1]
  subs x3, x3, #4
  b.ge 1b
  ret

str_exc: .asciz "\n*** EXCEPTION vec="
str_esr: .asciz " ESR="
str_elr: .asciz " ELR="
str_far: .asciz " FAR="
str_nl:  .asciz "\n"

.section .bss
.balign 4096
l1_table:
  .space 4096
