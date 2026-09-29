#!/bin/sh
# Build boot/uefi-probe/probe.c -> build/BOOTAA64.EFI (PE/COFF EFI application).
# Needs LLVM (clang) and lld-link, both keg-only Homebrew packages.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
LLVM=${LLVM:-/opt/homebrew/opt/llvm@21/bin}
LLD=${LLD:-/opt/homebrew/opt/lld@21/bin}
mkdir -p "$root/build"
"$LLVM/clang" --target=aarch64-unknown-windows -ffreestanding -fno-builtin \
  -fshort-wchar -fno-stack-protector -mgeneral-regs-only -fno-stack-check \
  -O2 -Wall -Wextra -Wno-unused-function -Wno-unused-parameter \
  -c "$here/probe.c" -o "$root/build/probe.obj"
"$LLD/lld-link" /subsystem:efi_application /entry:efi_main /nodefaultlib \
  /machine:arm64 /opt:ref /out:"$root/build/BOOTAA64.EFI" "$root/build/probe.obj"
ls -l "$root/build/BOOTAA64.EFI"
