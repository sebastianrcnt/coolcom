// Boot stub: bring the CPU to a sane EL1 state, then jump into HolyC KMain.
//  - drop from EL2 to EL1 if needed
//  - enable FP/SIMD (HolyC F64 code uses it)
//  - install the exception vectors (Arch.S)
//  - identity-map RAM + devices and turn on the MMU and caches

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
  ldr x19, =stack_top
  adr x20, primary
  b cpu_setup

// Secondary cores arrive here from PSCI CPU_ON with x0 = their stack top.
.global ap_start
ap_start:
  mov x19, x0
  adr x20, secondary
  // fall through

// Per-core setup: EL1, stack from x19, FP/SIMD, vectors; then jump to x20.
cpu_setup:
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
  mov sp, x19
  mov x0, #(3 << 20) // FP/SIMD on at EL1 and EL0
  msr cpacr_el1, x0
  ldr x0, =vectors
  msr vbar_el1, x0
  isb
  br x20

secondary:
  bl mmu_enable
  mrs x0, mpidr_el1
  and x0, x0, #0xff
  ldr x1, =HC_KMainAP
  blr x1
  b park

primary:
  // Zero .bss (holds the page table).
  ldr x0, =__bss_start
  ldr x1, =__bss_end
2:
  cmp x0, x1
  b.hs 3f
  str xzr, [x0], #8
  b 2b
3:
  bl mmu_tables
  bl mmu_enable

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

// Identity map: [0,1GB) devices, [1GB,2GB) RAM. Built once by the primary core.
mmu_tables:
  adr x0, l1_table
  ldr x1, =(0x00000000 | BLK_DEVICE)
  str x1, [x0, #0]
  ldr x1, =(0x40000000 | BLK_NORMAL)
  str x1, [x0, #8]
  dsb ish
  ret

// Turn on the MMU and caches on the calling core.
mmu_enable:
  adr x0, l1_table
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

.section .bss
.balign 4096
l1_table:
  .space 4096
