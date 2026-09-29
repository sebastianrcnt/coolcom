// Linux arm64 Image entry. m1n1 and coolvm both enter at the first byte.
#define MT_DEVICE 0
#define MT_NORMAL 1
#define BLK_NORMAL ((1 << 0) | (MT_NORMAL << 2) | (3 << 8) | (1 << 10))
#define BLK_DEVICE ((1 << 0) | (MT_DEVICE << 2) | (1 << 10) | (1ULL << 53) | (1ULL << 54))

.section .text.boot
.global _start
_start:
  b boot_entry
  .word 0
  .quad 0                    // text_offset: loaded at the chosen image base
  .quad image_end - _start   // image_size includes BSS and boot stacks
  .quad 8                    // 16K pages in the Image flags
  .quad 0
  .quad 0
  .quad 0
  .ascii "ARM\x64"           // offset 0x38
  .word 0
boot_entry:
  mov x21, x0
  // Aiwnios AOT emits absolute 64-bit pointers in aligned literal slots.
  // Relocate them when m1n1 chooses a different 2 MiB-aligned load base.
  adr x24, _start
  ldr x22, =_start
  ldr x23, =image_end
  sub x25, x24, x22
  cbz x25, 2f
  sub x26, x23, x22
  add x26, x24, x26
  mov x27, x24
1:
  add x28, x27, #8
  cmp x28, x26
  b.hi 2f
  ldr x28, [x27]
  cmp x28, x22
  b.lo 3f
  cmp x28, x23
  b.hi 3f
  add x28, x28, x25
  str x28, [x27]
3:
  add x27, x27, #8
  b 1b
2:
  dsb sy
  ic iallu
  isb
  mrs x0, mpidr_el1
  and x0, x0, #0xff
  mrs x1, mpidr_el1
  ubfx x1, x1, #16, #8
  add x0, x0, x1, lsl #2   // logical E0..3, P0..3
  cbnz x0, park
  ldr x19, =boot_stack_top
  adr x20, primary
  b cpu_setup

.global ap_start
ap_start:
  mrs x0, mpidr_el1
  and x19, x0, #0xff
  ubfx x0, x0, #16, #8
  add x19, x19, x0, lsl #2
  ldr x0, =ap_stacks
  add x19, x0, x19, lsl #16
  add x19, x19, #65536
  adr x20, secondary

cpu_setup:
  mrs x0, CurrentEL
  cmp x0, #8
  b.ne 1f
  // m1n1 leaves E2H/TGE enabled. Drop with routing cleared.
  mov x0, #(1 << 31)
  msr hcr_el2, x0
  mov x0, #3
  msr cnthctl_el2, x0
  msr cptr_el2, xzr
  mov x0, #0x3c5
  msr spsr_el2, x0
  adr x0, 1f
  msr elr_el2, x0
  isb
  eret
1:
  mov sp, x19
  mov x0, #(3 << 20)
  msr cpacr_el1, x0
  ldr x0, =vectors
  msr vbar_el1, x0
  ic iallu
  dsb sy
  isb
  br x20

secondary:
  bl mmu_enable
  mrs x0, mpidr_el1
  and x1, x0, #0xff
  ubfx x0, x0, #16, #8
  add x0, x1, x0, lsl #2
  ldr x1, =HC_KMainAP
  blr x1
  b park

primary:
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
  ldr x0, =KBSS_START
  ldr x1, =KBSS_END
4:
  cmp x0, x1
  b.hs 5f
  str xzr, [x0], #8
  b 4b
5:
  ldr x20, =MAIN_TABLE
6:
  ldr x1, [x20], #8
  cbz x1, 7f
  blr x1
  b 6b
7:
  ldr x0, =image_end
  mov x1, x21
  ldr x2, =KMAIN
  blr x2
park:
  wfe
  b park

// Identity-map SoC MMIO 0x2_0000_0000..0x2_ffff_ffff as nGnRnE,
// and DRAM 0x8_0000_0000..0xc_0000_0000 as Normal WB, 32MB blocks.
mmu_tables:
  adr x0, l2_table
  mov x2, #255
  mov x3, #384
8:
  lsl x4, x2, #25
  ldr x5, =BLK_DEVICE
  orr x4, x4, x5
  str x4, [x0, x2, lsl #3]
  add x2, x2, #1
  cmp x2, x3
  b.lo 8b
  mov x2, #1024
  mov x3, #1536
9:
  lsl x4, x2, #25
  ldr x5, =BLK_NORMAL
  orr x4, x4, x5
  str x4, [x0, x2, lsl #3]
  add x2, x2, #1
  cmp x2, x3
  b.lo 9b
  dsb sy
  ret

mmu_enable:
  adr x0, l2_table
  ldr x1, =0xff00
  msr mair_el1, x1
  // 16K granule, 36-bit VA, 40-bit PA, inner-shareable WB walks.
  ldr x1, =((28 << 0) | (1 << 8) | (1 << 10) | (3 << 12) | (2 << 14) | (1 << 23) | (2 << 32))
  msr tcr_el1, x1
  msr ttbr0_el1, x0
  isb
  tlbi vmalle1
  dsb sy
  isb
  mrs x1, sctlr_el1
  orr x1, x1, #(1 << 0)
  orr x1, x1, #(1 << 2)
  orr x1, x1, #(1 << 12)
  msr sctlr_el1, x1
  isb
  ret

.section .bss
.balign 16384
l2_table: .space 16384
.balign 16
boot_stack: .space 65536
boot_stack_top:
ap_stacks: .space 8 * 65536
