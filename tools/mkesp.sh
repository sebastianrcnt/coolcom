#!/bin/sh
# Create build/esp.img: raw GPT disk with one FAT32 EFI System Partition that
# holds EFI/BOOT/BOOTAA64.EFI.  No sudo; needs Homebrew mtools + gptfdisk:
#   brew install mtools gptfdisk
#
#   tools/mkesp.sh [-o OUT.img] [-e BOOTAA64.EFI] [-c probe.cfg] [-s MiB]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
out=$root/build/esp.img
efi=$root/build/BOOTAA64.EFI
cfg=
size=64
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -e) efi=$2; shift 2 ;;
    -c) cfg=$2; shift 2 ;;
    -s) size=$2; shift 2 ;;
    *) echo "usage: $0 [-o out.img] [-e BOOTAA64.EFI] [-c probe.cfg] [-s MiB]" >&2; exit 2 ;;
  esac
done
for t in sgdisk mformat mmd mcopy; do
  command -v $t >/dev/null || { echo "missing $t (brew install mtools gptfdisk)" >&2; exit 1; }
done
[ -f "$efi" ] || { echo "no such file: $efi" >&2; exit 1; }
mkdir -p "$(dirname "$out")"
rm -f "$out"
dd if=/dev/zero of="$out" bs=1048576 count="$size" 2>/dev/null
sgdisk -o -n 1:2048:0 -t 1:EF00 -c 1:ESP "$out" >/dev/null
first=$(sgdisk -i 1 "$out" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
last=$(sgdisk -i 1 "$out" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
count=$((last - first + 1))
off=$((first * 512))
MTOOLS_SKIP_CHECK=1 mformat -i "$out@@$off" -F -T "$count" -v COOLESP ::
MTOOLS_SKIP_CHECK=1 mmd -i "$out@@$off" ::EFI ::EFI/BOOT
MTOOLS_SKIP_CHECK=1 mcopy -i "$out@@$off" "$efi" ::EFI/BOOT/BOOTAA64.EFI
if [ -n "$cfg" ]; then
  MTOOLS_SKIP_CHECK=1 mcopy -i "$out@@$off" "$cfg" ::probe.cfg
fi
echo "created $out (ESP at sector $first, $count sectors)"
