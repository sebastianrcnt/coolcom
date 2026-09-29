ENTRY(_start)
/* Symbols from binlink.py (build/syms.ld) are passed on the ld command line. */
SECTIONS {
  . = 0x40080000;
  .text : { *(.text.boot) *(.text*) *(.rodata*) *(.data*) }
  . = ALIGN(4096);
  __bss_start = .;
  .bss (NOLOAD) : { *(.bss*) }
  . = ALIGN(8);
  __bss_end = .;
  /* The relocated HolyC kernel module; must match ORG in tools/binlink.py. */
  . = 0x40100000;
  ASSERT(__bss_end <= 0x40100000, "boot stub overlaps the kernel module")
  .kernel : { *(.kernel) }
  /* Zero-filled globals of the module, laid out by binlink.py. */
  . = KBSS_END;
  . = ALIGN(16); . += 0x10000; stack_top = .;
}
