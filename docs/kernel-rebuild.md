# Rebuilding the kernel inside the OS

TempleOS recompiles itself from its own disk. coolcom does the same: the
kernel sources are on `C:`, the shell compiles them with `Cmp`, and the rest
of what the host build does after `coolc` is ported to Cool.

## Sources on C:

`tools/disk-files.sh` (run by `make run` through `disk-seed`, and by
`make disk-install`) copies:

| On C: | From the repository |
|---|---|
| `C:/Kernel/*` | `os/Kernel/*`, including `NetParse.cool`, which `make` generates from `NetParse.warm` |
| `C:/Cool/Runtime/*.cool` | `coolc/Runtime/*.cool` |
| `C:/Cool/Fmt/HCTok.cool` | `coolc/Fmt/HCTok.cool` |
| `C:/Kernel/BootStub.BIN` | `build/BootStub.BIN` (the prebuilt assembly, below) |

The repository's `Kernel.cool` includes the runtime as `../../coolc/Runtime/...`.
The installer maps those includes (and the tokenizer include) to `C:/Cool/...`
in the disk copy, leaving host sources unchanged. `Man` searches both
`C:/Kernel` and `C:/Cool`.

`Cmp("C:/Kernel/Kernel.cool", "C:/Kernel.BIN")` in the shell takes about one
second and writes a BIN equal to the host's `build/Kernel.BIN` byte for byte.

## MakeKernel

`MakeKernel(out="C:/Kernel.Image", dir="C:/Kernel", prelude="C:/Kernel.coolh")`
in the shell does what `make` does after `coolc` and writes the Image:

1. `Cmp(dir/Kernel.cool, dir/Kernel.BIN)`.
2. `KLink` (`os/Kernel/KLink.cool`), a port of `tools/binlink.py`, links the
   module at `MODULE_BASE`: code, main table, initialized globals, the
   relocation table, the kernel symbol table, the blobs (`SHELL_PRELUDE` from
   `prelude`, `ARM64_OPS` from `dir/Arm64Ops.csv`), the zeroed globals, the
   imports. It also writes `dir/Syms.ld`, the text binlink.py writes to
   `build/syms.ld`.
3. `KernelImage` (`os/Kernel/MakeKernel.cool`) assembles the Image as
   `os/Kernel/Kernel.ld` and `objcopy -O binary` do: the boot stub from the
   image base, zeros up to `MODULE_BASE`, the module, zeros up to `KBSS_END`,
   then the console font (`dir/Unifont.BIN`, `.fontdata`). The header's
   `image_size` and every other reference of the assembly to the module or to
   what follows it are relocations it applies (`.mmutables` is placed at the
   next 16 KiB boundary after the font, `image_end` after it).

It takes about 1.2 s (1 s of it compiling). `Reboot("C:/Kernel.Image")` boots
the result (below).

### The prebuilt boundary: BootStub.BIN

The OS has no assembler, so the assembly (`Boot.S`, `Arch.S`, `Blob.S` with
the compiler seed `coolc/seed/Compiler.BIN`, `FontData.S`) comes from the host
as `build/BootStub.BIN` (`make build/BootStub.BIN`, `tools/mkbootstub.py`).
It is the assembly linked alone, like the Makefile's pass 1, with `-q` so the
relocations stay in the ELF: the stub's bytes at their final addresses (they
do not depend on the module; the Makefile's pass 2 checks that), its 78
relocations (`ADR_PREL_PG_HI21`, `ADD_ABS_LO12_NC`, `ADR_PREL_LO21`,
`CONDBR19`, `JUMP26`, `PREL64`), and its symbols (`arch.syms`, which binlink
uses for HolyC imports of assembly routines and the symbol table). References
to binlink's symbols (`HC_*`, `KMAIN`, `RELOC_TABLE`, `KSYM_TABLE`, the blobs,
`KBSS_*`) and to `.fontdata`, `.mmutables` and `image_end` point at stand-ins
in the stub and are resolved by MakeKernel; the others are final. The file
format is at the top of `tools/mkbootstub.py`.

So edits to HolyC kernel sources on C: are rebuilt in the OS; edits to the
assembly, the compiler seed embedded by `Blob.S`, or the linker script need
the host. Two other inputs are host-made: the shell prelude (`C:/Kernel.coolh`,
`tools/mkprelude.py`), embedded as `SHELL_PRELUDE` as it is, and the font
(`os/Kernel/Unifont.BIN`, `make font`).

## Booting it: Reboot(image)

`Reboot("C:/Kernel.Image")` flushes the disks, reads the file into RAM
(identity mapped, so its address is physical), checks the `ARM\x64` magic,
writes the address and size to coolvm's finisher (offsets `0x8` and `0x10`)
and resets (`0x7777`). coolvm writes those bytes to a temporary file in
`$TMPDIR` and starts again with it as the kernel, with the same options (as
for every reset, minus `--input-script`); a later plain `Reboot` boots the
same Image again, and coolvm deletes the file when it exits or boots another.
The repository's `build/kernel.Image` is untouched. This is VM-only: on a real
M1 there is no finisher (`Reboot` says so and returns); there the Image would
have to go through m1n1 (`make m1n1-payload`) or a kexec-like handoff, which
does not exist yet.

## Check

`make kernel-rebuild-test` (part of `make test`, about 6 s) puts the sources,
the stub and the prelude on a fresh disk, and `C:/Init.cool`:

1. runs `MakeKernel`; the host later requires `C:/Kernel.Image` to equal
   `build/kernel.Image` and `C:/Kernel/Syms.ld` to equal `build/syms.ld`,
   byte for byte. There are no allowed differences. 35 words of the stub
   differ from the final Image before MakeKernel relocates them.
2. appends `I64 RebuildMark() { return 4242; }` to `C:/Kernel/Kernel.cool`,
   runs `MakeKernel("C:/Kernel2.Image")` and `Reboot("C:/Kernel2.Image")`;
3. on the second boot types, at the shell prompt, a line declaring
   `RebuildMark` (bound to the new kernel's symbol) and printing its value,
   then `Shutdown`. The host requires `mark 4242`, coolvm's message that it
   booted the Image the guest passed, and no temporary Image left behind.

Porting found a bug in `binlink.py`: an implicit string concatenation made the
`KMAIN`..`KSYM_TABLE` lines of `syms.ld` the separator between the blob
lines, so with fewer than two blobs they would have been lost. Fixed; the
Image did not change.
