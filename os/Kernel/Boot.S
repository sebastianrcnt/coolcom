#include "Asm.h"
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
  mrs x0, mpidr_el1
  and x0, x0, #0xff
  mrs x1, mpidr_el1
  ubfx x1, x1, #16, #8
  add x0, x0, x1, lsl #2   // logical E0..3, P0..3
  cbnz x0, park
  // m1n1 may load the Image at another 2 MiB-aligned address than the link
  // base. Add the load delta to every absolute U64 listed in the module's
  // relocation table (tools/binlink.py). The assembly itself is pc-relative.
  //   table: U64 link-time module base | U32 count | U32 pad | U32 offset[count]
  LA x0, MODULE_BASE       // where the module really is
  LA x1, RELOC_TABLE
  ldr x2, [x1]             // where it was linked
  sub x2, x0, x2           // delta
  cbz x2, 2f
  ldr w3, [x1, #8]
  add x1, x1, #16
1:
  cbz w3, 2f
  ldr w4, [x1], #4
  ldr x5, [x0, x4]
  add x5, x5, x2
  str x5, [x0, x4]
  add x6, x0, x4
  dc civac, x6             // drop any stale cached copy: the MMU is off, the stores bypass the caches
  sub w3, w3, #1
  b 1b
2:
  dsb sy
  ic iallu
  isb
  LA x19, boot_stack_top
  adr x20, primary
  b cpu_setup

.global ap_start
ap_start:
  mrs x0, mpidr_el1
  and x19, x0, #0xff
  ubfx x0, x0, #16, #8
  add x19, x19, x0, lsl #2
  LA x0, ap_stacks
  add x19, x0, x19, lsl #17
  add x19, x19, #131072
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
  LA x1, exception_stacks
  mrs x0, mpidr_el1
  and x2, x0, #0xff
  ubfx x0, x0, #16, #8
  add x0, x2, x0, lsl #2
  add x0, x0, #1
  add x1, x1, x0, lsl #14
  msr tpidrro_el0, x1
  mov sp, x19
  mov x0, #(3 << 20)
  msr cpacr_el1, x0
  LA x0, vectors
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
  LA x1, HC_KMainAP
  blr x1
  b park

primary:
  LA x0, __bss_start
  LA x1, __bss_end
2:
  cmp x0, x1
  b.hs 3f
  str xzr, [x0], #8
  b 2b
3:
  bl mmu_tables
  bl mmu_enable
  LA x0, KBSS_START
  LA x1, KBSS_END
4:
  cmp x0, x1
  b.hs 5f
  str xzr, [x0], #8
  b 4b
5:
  LA x20, MAIN_TABLE
6:
  ldr x1, [x20], #8
  cbz x1, 7f
  blr x1
  b 6b
7:
  LA x0, image_end
  mov x1, x21
  LA x2, KMAIN
  blr x2
park:
  wfe
  b park

// Identity-map SoC MMIO 0x2_0000_0000..0x2_ffff_ffff as nGnRnE,
// and DRAM 0x8_0000_0000..0xc_0000_0000 as Normal WB, 16 KiB pages.
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
  // Page-map the DRAM aperture before enabling translation. No live block
  // splitting (and no break-before-make window on the executing stack).
  LA x6, l3_tables
  LA x7, _start
  LA x8, boot_text_end
  LA x9, MODULE_BASE
  LA x10, KTEXT_END
  LA x12, boot_guard
  LA x13, ap_stacks
  LA x14, ap_stacks_end
  mov x2, #1024
  mov x3, #1536
9:
  orr x4, x6, #3
  str x4, [x0, x2, lsl #3]
  lsl x4, x2, #25
  mov x11, #2048
10:
  mov x5, #(BLK_NORMAL | 2)
  cmp x4, x7
  b.lo 11f
  cmp x4, x8
  b.lo 12f
  cmp x4, x9
  b.lo 11f
  cmp x4, x10
  b.hs 11f
12:
  orr x5, x5, #(1 << 7) // AP: EL1 read-only
11:
  orr x5, x5, x4
  cmp x4, x12
  b.eq 14f
  cmp x4, x13
  b.lo 15f
  cmp x4, x14
  b.hs 15f
  sub x15, x4, x13
  tst x15, #0x1c000
  b.ne 15f
14:
  mov x5, #0
15:
  str x5, [x6], #8
  add x4, x4, #16384
  subs x11, x11, #1
  b.ne 10b
  add x2, x2, #1
  cmp x2, x3
  b.lo 9b
  dsb sy
  ret

mmu_enable:
  adr x0, l2_table
  ldr x1, =0x44ff00   // attr0 Device-nGnRnE, attr1 Normal WB, attr2 Normal non-cacheable
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
.global l2_table
l2_table: .space 16384
.section .mmutables,"aw",@nobits
.balign 16384
l3_tables: .space 512 * 16384

.balign 16384
boot_guard: .space 16384
boot_stack: .space 65536
boot_stack_top:
 .balign 16384
ap_stacks: .space 8 * 131072
ap_stacks_end:

.balign 16384
exception_stacks: .space 8 * 16384


.text
.global ArchBootGuard
ArchBootGuard:
  cbnz x0, 1f
  LA x0, boot_guard
  ret
1:
  LA x1, ap_stacks
  add x0, x1, x0, lsl #17
  ret
