/* coolvm test guest: flat, position-independent Image. The address only matters
 * for the assembler's literal pool math; the guest uses adr/ldr= relative forms. */
ENTRY(_start)
SECTIONS
{
    . = 0x800200000;
    .text : { *(.text .text.*) *(.rodata .rodata.*) *(.data .data.*) }
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
