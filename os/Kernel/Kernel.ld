/* IMAGE_BASE and MODULE_BASE (= IMAGE_BASE + 2 MiB) come from the Makefile via --defsym. */
ENTRY(_start)
SECTIONS {
  . = IMAGE_BASE;
  .text : { *(.text.boot) *(.text*) *(.rodata*) *(.data*) }
  . = ALIGN(16384);
  __bss_start = .;
  .bss (NOLOAD) : { *(.bss*) }
  . = ALIGN(16);
  __bss_end = .;
  . = MODULE_BASE;
  ASSERT(__bss_end <= MODULE_BASE, "boot stub overlaps the kernel module")
  .kernel : { *(.kernel) }
  . = KBSS_END;
  . = ALIGN(16384);
  image_end = .;
}
