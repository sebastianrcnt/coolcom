#!/usr/bin/env python3
# Compare two Aiwnios BIN files for identical machine code.
# The 8-byte slots of absolute imports and global-variable references hold
# host addresses from the compiling runtime, so they are zeroed before comparing. Exit 0 if equal.
# Usage: bincmp.py a.BIN b.BIN
import struct, sys

def norm(path):
    d = bytearray(open(path, 'rb').read())
    po = struct.unpack_from('<Q', d, 0x10)[0]
    p = po
    while d[p]:
        et = d[p]; i = struct.unpack_from('<I', d, p + 1)[0]; p += 5
        if 2 <= et <= 12:
            p += 4
        e = d.index(b'\0', p); p = e + 1
        if et == 11:  # IET_IMM_I64: host address of the import
            d[0x20 + i:0x20 + i + 8] = bytes(8)
        elif et == 20:
            p += 4 * i
        elif et in (23, 24):
            size = struct.unpack_from('<q', d, p)[0]
            p += 8 + size
            for _ in range(i):  # {I32 patch_at, I32 addend}: slot gets the global's address
                at = struct.unpack_from('<i', d, p)[0]; p += 8
                d[0x20 + at:0x20 + at + 8] = bytes(8)
    return d, po

if __name__ == '__main__':
    a, pa = norm(sys.argv[1])
    b, pb = norm(sys.argv[2])
    if a == b:
        sys.exit(0)
    if pa != pb:
        print(f'code size differs: {pa - 0x20:#x} vs {pb - 0x20:#x}')
    n = min(len(a), len(b))
    diffs = [k for k in range(n) if a[k] != b[k]]
    if diffs:
        k = diffs[0]
        region = 'code' if k < min(pa, pb) else 'patch table'
        print(f'{len(diffs)} differing bytes; first at file offset {k:#x} ({region}, '
              f'code offset {k - 0x20:#x})')
        w = (k - 0x20) & ~3
        for off in range(max(0, w - 8), min(w + 12, min(pa, pb) - 0x20), 4):
            x = struct.unpack_from('<I', a, 0x20 + off)[0]
            y = struct.unpack_from('<I', b, 0x20 + off)[0]
            print(f'  {off:#06x}: {x:08x} {y:08x}' + ('  <--' if x != y else ''))
    sys.exit(1)
