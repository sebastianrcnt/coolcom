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
#define FR_SIZE   (FR_Q + 32 * 16)

.text

// Every vector saves x0/x1, records its index and joins except_common.
.macro VEC n
  .balign 0x80
  sub sp, sp, #FR_SIZE
  stp x0, x1, [sp, #FR_X]
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
  ldr x2, =HC_KExcept
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
  ldp x0, x1, [sp, #FR_X]
  add sp, sp, #FR_SIZE
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
  msr daifclr, #2
  ret

.global ArchIrqOff
ArchIrqOff:
  msr daifset, #2
  ret

.global ArchWfi
ArchWfi:
  wfi
  ret
