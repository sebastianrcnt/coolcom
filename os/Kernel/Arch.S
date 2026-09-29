#include "Asm.h"
// AArch64 glue that HolyC can't express: exception entry/exit and system
// register access. HolyC calls the Arch* routines through `import`
// declarations (see ArchA.HH); binlink.py resolves them from this object.
// HolyC functions are visible here as HC_<name> (see build/syms.ld).

// Exception frame layout, must match CExceptFrame in ArchA.HH.
#define FR_X      0       // x0..x30
#define FR_ELR    (31 * 8)
#define FR_SPSR   (32 * 8)
#define FR_ESR    (33 * 8)
#define FR_FAR    (34 * 8)
#define FR_VEC    (35 * 8)
#define FR_Q      (36 * 8) // q0..q31
#define FR_SP     (FR_Q + 32 * 16)
#define FR_SIZE   (FR_SP + 16)
// The Aiwnios code generator saves callee-saved registers below sp (stp x19, x20, [sp, #-16], then
// sub sp) and restores them the same way, so an interrupt between those two instructions would
// overwrite them with the exception frame. Leave a red zone under the interrupted sp untouched.
#define REDZONE   512

.text

// Every vector saves x0/x1, records its index and joins except_common.
.macro VEC n
  .balign 0x80
  .if \n == 4
  // Synchronous faults must work even when the task SP is in its guard.
  msr sp_el0, x0
  mrs x0, tpidrro_el0
  str x1, [x0, #-8]
  mov x1, sp
  mov sp, x0
  sub sp, sp, #(FR_SIZE + REDZONE)
  str x1, [sp, #FR_SP]
  ldr x1, [x0, #-8]
  mrs x0, sp_el0
  stp x0, x1, [sp, #FR_X]
  .else
  sub sp, sp, #(FR_SIZE + REDZONE)
  stp x0, x1, [sp, #FR_X]
  add x1, sp, #(FR_SIZE + REDZONE)
  str x1, [sp, #FR_SP]
  .endif
  mov x0, #\n
  b except_common
.endm

.balign 0x800
.global vectors
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

except_common:
  stp x2, x3, [sp, #FR_X + 2 * 8]
  stp x4, x5, [sp, #FR_X + 4 * 8]
  stp x6, x7, [sp, #FR_X + 6 * 8]
  stp x8, x9, [sp, #FR_X + 8 * 8]
  stp x10, x11, [sp, #FR_X + 10 * 8]
  stp x12, x13, [sp, #FR_X + 12 * 8]
  stp x14, x15, [sp, #FR_X + 14 * 8]
  stp x16, x17, [sp, #FR_X + 16 * 8]
  stp x18, x19, [sp, #FR_X + 18 * 8]
  stp x20, x21, [sp, #FR_X + 20 * 8]
  stp x22, x23, [sp, #FR_X + 22 * 8]
  stp x24, x25, [sp, #FR_X + 24 * 8]
  stp x26, x27, [sp, #FR_X + 26 * 8]
  stp x28, x29, [sp, #FR_X + 28 * 8]
  str x30, [sp, #FR_X + 30 * 8]
  mrs x1, elr_el1
  mrs x2, spsr_el1
  stp x1, x2, [sp, #FR_ELR]
  mrs x1, esr_el1
  mrs x2, far_el1
  stp x1, x2, [sp, #FR_ESR]
  str x0, [sp, #FR_VEC]
  add x1, sp, #FR_Q
  stp q0, q1, [x1], #32
  stp q2, q3, [x1], #32
  stp q4, q5, [x1], #32
  stp q6, q7, [x1], #32
  stp q8, q9, [x1], #32
  stp q10, q11, [x1], #32
  stp q12, q13, [x1], #32
  stp q14, q15, [x1], #32
  stp q16, q17, [x1], #32
  stp q18, q19, [x1], #32
  stp q20, q21, [x1], #32
  stp q22, q23, [x1], #32
  stp q24, q25, [x1], #32
  stp q26, q27, [x1], #32
  stp q28, q29, [x1], #32
  stp q30, q31, [x1], #32

  // KExcept(vec, frame); it may edit the frame (e.g. ELR) before we return.
  mov x1, sp
  LA x2, HC_KExcept
  blr x2

  add x1, sp, #FR_Q
  ldp q0, q1, [x1], #32
  ldp q2, q3, [x1], #32
  ldp q4, q5, [x1], #32
  ldp q6, q7, [x1], #32
  ldp q8, q9, [x1], #32
  ldp q10, q11, [x1], #32
  ldp q12, q13, [x1], #32
  ldp q14, q15, [x1], #32
  ldp q16, q17, [x1], #32
  ldp q18, q19, [x1], #32
  ldp q20, q21, [x1], #32
  ldp q22, q23, [x1], #32
  ldp q24, q25, [x1], #32
  ldp q26, q27, [x1], #32
  ldp q28, q29, [x1], #32
  ldp q30, q31, [x1], #32
  ldp x1, x2, [sp, #FR_ELR]
  msr elr_el1, x1
  msr spsr_el1, x2
  ldp x2, x3, [sp, #FR_X + 2 * 8]
  ldp x4, x5, [sp, #FR_X + 4 * 8]
  ldp x6, x7, [sp, #FR_X + 6 * 8]
  ldp x8, x9, [sp, #FR_X + 8 * 8]
  ldp x10, x11, [sp, #FR_X + 10 * 8]
  ldp x12, x13, [sp, #FR_X + 12 * 8]
  ldp x14, x15, [sp, #FR_X + 14 * 8]
  ldp x16, x17, [sp, #FR_X + 16 * 8]
  ldp x18, x19, [sp, #FR_X + 18 * 8]
  ldp x20, x21, [sp, #FR_X + 20 * 8]
  ldp x22, x23, [sp, #FR_X + 22 * 8]
  ldp x24, x25, [sp, #FR_X + 24 * 8]
  ldp x26, x27, [sp, #FR_X + 26 * 8]
  ldp x28, x29, [sp, #FR_X + 28 * 8]
  ldr x30, [sp, #FR_X + 30 * 8]
  mov x1, sp
  ldr x0, [x1, #FR_SP]
  mov sp, x0
  ldp x0, x1, [x1, #FR_X]
  eret

// System register accessors. Each is a plain AAPCS64 function.
.macro GETTER name, reg
.global \name
\name:
  mrs x0, \reg
  ret
.endm
.macro SETTER name, reg
.global \name
\name:
  msr \reg, x0
  isb
  ret
.endm

GETTER ArchCntFrq,    cntfrq_el0
GETTER ArchCntVct,    cntvct_el0
SETTER ArchCntvTvalSet, cntv_tval_el0
SETTER ArchCntvCvalSet, cntv_cval_el0
SETTER ArchCntvCtlSet,  cntv_ctl_el0
GETTER ArchMpidr,     mpidr_el1
GETTER ArchDaif,      daif

.global ArchIrqOn
ArchIrqOn:
  msr daifclr, #3
  ret

.global ArchIrqOff
ArchIrqOff:
  msr daifset, #3
  ret

.global ArchIntRestore
ArchIntRestore:
  msr daifclr, #3
  tst x0, #0x80
  b.eq 1f
  msr daifset, #2
1:
  tst x0, #0x40
  b.eq 2f
  msr daifset, #1
2:
  ret

.global ArchWfi
ArchWfi:
  wfi
  ret

.global ArchWfe
ArchWfe:
  wfe
  ret

.global ArchSev
ArchSev:
  sev
  ret

GETTER ArchTpidr, tpidr_el1
SETTER ArchTpidrSet, tpidr_el1

// ArchCpuNum(): core number from MPIDR Aff0.
.global ArchCpuNum
ArchCpuNum:
  mrs x0, mpidr_el1
  and x1, x0, #0xff
  ubfx x0, x0, #16, #8
  add x0, x1, x0, lsl #2
  ret

// ArchXchg(I64 *p, I64 v): atomically store v, return the old value.
.global ArchXchg
ArchXchg:
  ldaxr x2, [x0]
  stlxr w3, x1, [x0]
  cbnz w3, ArchXchg
  mov x0, x2
  ret

// ArchCas(I64 *p, I64 old, I64 new): if *p==old store new; returns the value seen.
.global ArchCas
ArchCas:
  ldaxr x3, [x0]
  cmp x3, x1
  b.ne 1f
  stlxr w4, x2, [x0]
  cbnz w4, ArchCas
  mov x0, x3
  ret
1:
  clrex
  mov x0, x3
  ret

// ArchAdd(I64 *p, I64 v): atomic add, returns the new value.
.global ArchAdd
ArchAdd:
  ldaxr x2, [x0]
  add x2, x2, x1
  stlxr w3, x2, [x0]
  cbnz w3, ArchAdd
  mov x0, x2
  ret

// ArchStoreRel(I64 *p, I64 v): store with release semantics (lock release).
.global ArchStoreRel
ArchStoreRel:
  stlr x1, [x0]
  sev
  ret

// Single-register MMIO operations required by Hypervisor.framework exits.
.global ArchMmioRead32
ArchMmioRead32:
  ldr w0, [x0]
  ret
.global ArchMmioWrite32
ArchMmioWrite32:
  str w1, [x0]
  ret
.global ArchSpinRelease
ArchSpinRelease:
  str x1, [x0]
  dc civac, x0
  dsb sy
  sev
  ret
GETTER ArchCntvCtl, cntv_ctl_el0
GETTER ArchIpiStatus, S3_5_C15_C1_1
.global ArchFiqSourcesInit
ArchFiqSourcesInit:
  msr cntv_ctl_el0, xzr
  msr S3_1_C15_C0_0, xzr // PMCR0: PMU FIQ mode off
  msr S3_7_C15_C0_4, xzr // UPMCR0: uncore PMU FIQ mode off
  mov x0, #1
  msr S3_5_C15_C1_1, x0 // stale fast IPI
  isb
  ret
SETTER ArchIpiAck, S3_5_C15_C1_1
.global ArchIpiSend
ArchIpiSend:
  msr S3_5_C15_C0_1, x0
  isb
  ret
// ArchApEntry(): address for ArchSpinRelease to start secondary cores at.
.global ArchApEntry
ArchApEntry:
  LA x0, ap_start
  ret

// Task switching. A switched-out task's stack holds its callee-saved
// registers (AAPCS64: x19-x30, d8-d15); everything else was already saved
// by the compiler around the Yield call.
#define CTX_SIZE (20 * 8)

// ArchCtxSwitch(U8 **save_sp, U8 *new_sp)
.global ArchCtxSwitch
ArchCtxSwitch:
  sub sp, sp, #CTX_SIZE
  stp x19, x20, [sp, #0]
  stp x21, x22, [sp, #16]
  stp x23, x24, [sp, #32]
  stp x25, x26, [sp, #48]
  stp x27, x28, [sp, #64]
  stp x29, x30, [sp, #80]
  stp d8, d9, [sp, #96]
  stp d10, d11, [sp, #112]
  stp d12, d13, [sp, #128]
  stp d14, d15, [sp, #144]
  mov x2, sp
  str x2, [x0]
  mov sp, x1
  ldp x19, x20, [sp, #0]
  ldp x21, x22, [sp, #16]
  ldp x23, x24, [sp, #32]
  ldp x25, x26, [sp, #48]
  ldp x27, x28, [sp, #64]
  ldp x29, x30, [sp, #80]
  ldp d8, d9, [sp, #96]
  ldp d10, d11, [sp, #112]
  ldp d12, d13, [sp, #128]
  ldp d14, d15, [sp, #144]
  add sp, sp, #CTX_SIZE
  ret

// First "return" of a new task: its initial frame has x30 = here,
// x19 = the task function, x20 = its argument.
task_start:
  mov x0, x20
  blr x19
  LA x1, HC_Exit
  blr x1
  b .

// ArchTaskStartAddr(): the address new task frames return to.
.global ArchTaskStartAddr
ArchTaskStartAddr:
  LA x0, task_start
  ret

// Barriers and MMU maintenance for device drivers.
.global ArchDsb
ArchDsb:
  dsb sy
  ret

.global ArchTlbFlush
ArchTlbFlush:
  dsb sy
  tlbi vmalle1is
  dsb sy
  isb
  ret

// ArchL2Table(): the boot level-2 translation table (Boot.S), 32 MiB entries.
.global ArchL2Table
ArchL2Table:
  LA x0, l2_table
  ret

// ArchICacheSync(U8 *addr, I64 len): make code just written at addr visible to
// instruction fetch on every core (clean D to PoU, invalidate I, barriers).
.global ArchICacheSync
ArchICacheSync:
  cbz x1, 3f
  mrs x3, ctr_el0
  mov x5, #4
  add x1, x0, x1
  ubfx x4, x3, #16, #4     // DminLine: log2 of the line size in words
  lsl x4, x5, x4
  sub x6, x4, #1
  bic x2, x0, x6
1:
  dc cvau, x2
  add x2, x2, x4
  cmp x2, x1
  b.lo 1b
  dsb ish
  and x4, x3, #0xf         // IminLine
  lsl x4, x5, x4
  sub x6, x4, #1
  bic x2, x0, x6
2:
  ic ivau, x2
  add x2, x2, x4
  cmp x2, x1
  b.lo 2b
  dsb ish
3:
  isb
  ret

// Code built by the Cool compiler reads Fs through x28 (Fs = [x28]); kernel
// HolyC never uses x28 and task switches preserve it. ArchX28Set(p) sets it
// for the running task.
.global ArchX28Set
ArchX28Set:
  mov x28, x0
  ret

// ArchSetJmp(I64 *ctx) / ArchLongJmp(I64 *ctx): the compiler's try/catch
// context (AIWNIOS_SetJmp/LongJmp, layout as coolc/Host/except.S).
.global ArchSetJmp
ArchSetJmp:
  stp x19, x20, [x0, #8]
  stp x21, x22, [x0, #24]
  stp x23, x24, [x0, #40]
  stp x25, x26, [x0, #56]
  str x27, [x0, #72]
  stp x29, x30, [x0, #88]
  stp d8, d9, [x0, #104]
  stp d10, d11, [x0, #120]
  stp d12, d13, [x0, #136]
  stp d14, d15, [x0, #152]
  mov x1, sp
  str x1, [x0, #168]
  mov x0, #0
  ret

.global ArchLongJmp
ArchLongJmp:
  ldp x19, x20, [x0, #8]
  ldp x21, x22, [x0, #24]
  ldp x23, x24, [x0, #40]
  ldp x25, x26, [x0, #56]
  ldr x27, [x0, #72]
  ldp x29, x30, [x0, #88]
  ldp d8, d9, [x0, #104]
  ldp d10, d11, [x0, #120]
  ldp d12, d13, [x0, #136]
  ldp d14, d15, [x0, #152]
  ldr x1, [x0, #168]
  mov sp, x1
  mov x0, #1
  ret

// Names the TempleOS library calls (coolc/Runtime NativeExcept.HC: try/catch).
.global AIWNIOS_SetJmp
AIWNIOS_SetJmp:
  b ArchSetJmp
.global AIWNIOS_LongJmp
AIWNIOS_LongJmp:
  b ArchLongJmp

// F64 functions that are one instruction (KMathC.HC has the rest).
.global Sqrt
Sqrt:
  fsqrt d0, d0
  ret
.global Floor
Floor:
  frintm d0, d0
  ret
.global Ceil
Ceil:
  frintp d0, d0
  ret
.global Round
Round:
  frinta d0, d0
  ret
