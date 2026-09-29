#!/bin/sh
# Fetch and build what a real-hardware boot payload needs (docs/m1-platform.md),
# in the gitignored vendor/ directory, at the revisions the platform notes cite:
#   vendor/m1n1/build/m1n1.bin  m1n1 stage 2 (AsahiLinux/m1n1 @ M1N1_REV), built
#                               with Homebrew llvm@21 + lld@21 and rustup's rust-src
#                               (BUILDSTD=1; the first build takes about 10 minutes)
#   vendor/asahi-dts/t8103-j274.dtb  the Mac mini (M1, 2020) device tree, from
#                               AsahiLinux/linux @ LINUX_REV, preprocessed and dtc'd
# Prints the two paths on the last two lines. Used by `make m1n1-payload`.
set -eu
M1N1_REV=${M1N1_REV:-647ae30533bc}
LINUX_REV=${LINUX_REV:-77cb8f24c238}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=$ROOT/vendor
mkdir -p "$V"

M1N1=$V/m1n1
if [ ! -s "$M1N1/build/m1n1.bin" ]; then
  if [ ! -f "$M1N1/Makefile" ]; then
    mkdir -p "$M1N1"
    curl -sfL "https://github.com/AsahiLinux/m1n1/archive/$M1N1_REV.tar.gz" -o "$V/m1n1.tar.gz"
    tar -xzf "$V/m1n1.tar.gz" -C "$M1N1" --strip-components 1
  fi
  LLVM=$(brew --prefix llvm@21)
  LLD=$(brew --prefix lld@21)
  make -C "$M1N1" -j8 BUILDSTD=1 LLVMCONFIG="$LLVM/bin/llvm-config" LLDDIR="$LLD/bin/" \
    build/m1n1.bin >"$V/m1n1-build.log" 2>&1 || { tail -20 "$V/m1n1-build.log"; exit 1; }
fi

DTS=$V/asahi-dts
DTB=$DTS/t8103-j274.dtb
if [ ! -s "$DTB" ]; then
  # Fetch t8103-j274.dts and everything it #includes, then cpp + dtc as Linux does.
  python3 - "$DTS" "$LINUX_REV" <<'PY'
import os, re, sys, urllib.request
root, rev = sys.argv[1], sys.argv[2]
base = "https://raw.githubusercontent.com/AsahiLinux/linux/%s/" % rev
todo, seen = ["arch/arm64/boot/dts/apple/t8103-j274.dts"], set()
while todo:
    path = todo.pop()
    if path in seen:
        continue
    seen.add(path)
    dest = os.path.join(root, path)
    if not os.path.exists(dest):
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        data = urllib.request.urlopen(base + path).read()
        open(dest, "wb").write(data)
    for kind, inc in re.findall(r'^\s*#include\s*([<"])([^>"]+)[>"]', open(dest).read(), re.M):
        if kind == '"':
            todo.append(os.path.normpath(os.path.join(os.path.dirname(path), inc)))
        else:
            todo.append("include/" + inc)
PY
  clang -E -P -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$DTS/include" \
    "$DTS/arch/arm64/boot/dts/apple/t8103-j274.dts" -o "$DTS/t8103-j274.pp.dts"
  # Asahi's dtc accepts floating-point cells (<7.5>) and stores them as IEEE 754
  # big-endian (scripts/dtc/dtc-parser.y, data_append_float); upstream dtc does
  # not, so write them as the equivalent hex cells (32-bit, or 64-bit after /bits/ 64).
  python3 - "$DTS/t8103-j274.pp.dts" <<'PY'
import re, struct, sys
p = sys.argv[1]
num = re.compile(r'(?<![\w.])[-+]?(?:\d+\.\d*|\d*\.\d+)(?:e[-+]?\d+)?f?(?![\w.])')
def cells(m):
    fmt, width = ('>d', 16) if m.group(1) else ('>f', 8)
    conv = lambda f: '0x%0*x' % (width, int.from_bytes(struct.pack(fmt, float(f.group(0).rstrip('f'))), 'big'))
    return (m.group(1) or '') + '<' + num.sub(conv, m.group(2)) + '>'
s = open(p).read()
open(p, 'w').write(re.sub(r'(/bits/\s*64\s*)?<([^<>"]*)>', cells, s))
PY
  dtc -q -I dts -O dtb -o "$DTB" "$DTS/t8103-j274.pp.dts"
fi
echo "$M1N1/build/m1n1.bin"
echo "$DTB"
