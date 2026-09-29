/* IMAGE_BASE and MODULE_BASE (= IMAGE_BASE + 2 MiB) come from the Makefile via --defsym. */
ENTRY(_start)
SECTIONS {
  . = IMAGE_BASE;
  .text : { *(.text.boot) *(.text*) *(.rodata*) }
  . = ALIGN(16384);
  boot_text_end = .;
  .data : { *(.data*) }
  __bss_start = ALIGN(16384);
  . = __bss_start;
  .bss (NOLOAD) : { *(.bss*) }
  . = ALIGN(16);
  __bss_end = .;
  . = MODULE_BASE;
  ASSERT(__bss_end <= MODULE_BASE, "boot stub overlaps the kernel module")
  .kernel : { *(.kernel) }
  . = KBSS_END;
  .fontdata : { *(.fontdata) }
  . = ALIGN(16384);
  .mmutables (NOLOAD) : { *(.mmutables) }
  image_end = .;
}
