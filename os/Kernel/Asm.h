// Shared assembler macros.
// The Image can be loaded at another 2 MiB-aligned address than it is linked
// at (tools/binlink.py, Boot.S), and only the HolyC module's absolute
// pointers are relocated. Assembly must therefore stay position independent:
// take addresses with LA (pc-relative), never `ldr xN, =sym` or `.quad sym`.
// tools/reloc-check.py fails the build if an absolute relocation slips in.
.macro LA reg, sym
  adrp \reg, \sym
  add \reg, \reg, :lo12:\sym
.endm
