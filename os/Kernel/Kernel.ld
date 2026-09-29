ENTRY(_start)
SECTIONS {
  . = 0x800200000;
  .text : { *(.text.boot) *(.text*) *(.rodata*) *(.data*) }
  . = ALIGN(16384);
  __bss_start = .;
  .bss (NOLOAD) : { *(.bss*) }
  . = ALIGN(16);
  __bss_end = .;
  . = 0x800400000;
  ASSERT(__bss_end <= 0x800400000, "boot stub overlaps the kernel module")
  .kernel : { *(.kernel) }
  . = KBSS_END;
  . = ALIGN(16384);
  image_end = .;
}
