#!/bin/sh
# Disassemble the code of two Aiwnios BINs and diff them (debug aid).
# Usage: bindiff.sh ref.BIN port.BIN
S=${TMPDIR:-/tmp}/bindiff.$$; mkdir -p "$S"; trap 'rm -rf "$S"' EXIT
for n in 1 2; do
  f=$(eval echo \$$n)
  python3 -c "
import sys; sys.path.insert(0, '$(dirname "$0")')
from bincmp import norm  # zero the host-address slots first
d, po = norm('$f')
open('$S/c$n.raw','wb').write(bytes(d[0x20:po]))"
  aarch64-elf-objdump -D -b binary -m aarch64 "$S/c$n.raw" | sed -n '8,$p' | cut -f2- > "$S/d$n.txt"
done
diff "$S/d1.txt" "$S/d2.txt" | head -${LINES:-40}
