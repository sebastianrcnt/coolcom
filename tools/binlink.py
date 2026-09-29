import struct, sys
ORG = 0x40100000  # where the BIN module lands; must match os/Kernel/Kernel.ld
data = open(sys.argv[1], 'rb').read()
hdr = 0x20
patch_off = struct.unpack_from('<Q', data, 0x10)[0]
code = bytearray(data[hdr:patch_off])
p, syms, imports, cur = patch_off, {}, [], None
while data[p]:
    et = data[p]; i = struct.unpack_from('<I', data, p+1)[0]; p += 5
    if 2 <= et <= 12: p += 4
    e = data.index(b'\0', p); name = data[p:e].decode(); p = e+1
    if name: cur = name
    if et in (16, 17): syms[cur] = i
    elif et == 11: imports.append((i, cur))
    else: sys.exit(f'unhandled patch type {et} for {cur}')
for off, name in imports:
    struct.pack_into('<Q', code, off, ORG + syms[name])
open(sys.argv[2], 'wb').write(code)
print('exports', {k: hex(ORG+v) for k, v in syms.items()})
open(sys.argv[3], 'w').write(f'KMAIN = {ORG + syms["KMain"]:#x};\n')
