ENTRY(_start)
INCLUDE build/syms.ld
SECTIONS {
  . = 0x40080000;
  .text : { *(.text.boot) *(.text*) *(.rodata*) *(.data*) }
  . = 0x40081000;
  .kernel : { *(.kernel) }
  . = ALIGN(16); . += 0x10000; stack_top = .;
}
