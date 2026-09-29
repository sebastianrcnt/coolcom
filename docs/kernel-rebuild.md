# Rebuilding the kernel inside the OS

TempleOS recompiles itself from its own disk. coolcom does the same: the
kernel sources are on `C:`, the shell compiles them with `Cmp`, and the rest
of what the host build does after `coolc` is ported to Cool.

## Sources on C:

`make run` (`disk-seed`, or `make disk-install` to overwrite) copies:

| On C: | From the repository |
|---|---|
| `C:/Kernel/*` | `os/Kernel/*` |
| `C:/coolc/Runtime/*.HC` | `coolc/Runtime/*.HC` |
| `C:/coolc/Fmt/HCTok.HC` | `coolc/Fmt/HCTok.HC` |

`Kernel.HC` includes the runtime as `../../coolc/Runtime/...`; `..` stops at
the root, so from `C:/Kernel` that is `C:/coolc/Runtime`. The target is
`make disk-kernel-src KDISK=<image>` for any FAT32 image.

`Cmp("C:/Kernel/Kernel.HC", "C:/Kernel.BIN")` in the shell takes about one
second and writes a BIN equal to the host's `build/Kernel.BIN` byte for byte.
