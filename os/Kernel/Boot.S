.section .text.boot
.global _start
_start:
  mrs x0, mpidr_el1
  and x0, x0, #3
  cbnz x0, park
  ldr x0, =stack_top
  mov sp, x0
  ldr x1, =KMAIN
  blr x1
park:
  wfe
  b park
