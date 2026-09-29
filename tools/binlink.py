import struct, sys
# Relocates an Aiwnios AOT BIN to ORG and resolves its patch table.
# Patch table semantics follow Aiwnios c/loader.c and Src/KLoadARM.HC.
ORG = 0x40100000  # where the BIN module lands (header stripped); must match os/Kernel/Kernel.ld

IET_END = 0
IET_REL_I8, IET_IMM_U8, IET_REL_I16, IET_IMM_U16 = 4, 5, 6, 7
IET_REL_I32, IET_IMM_U32, IET_REL_I64, IET_IMM_I64 = 8, 9, 10, 11
IET_REL_I0, IET_REL_RISCV = 2, 12
IET_REL32_EXPORT, IET_IMM32_EXPORT, IET_REL64_EXPORT, IET_IMM64_EXPORT = 16, 17, 18, 19
IET_ABS_ADDR = 20
IET_DATA_HEAP = 23
NAMES = {21: 'CODE_HEAP', 22: 'ZEROED_CODE_HEAP', 23: 'DATA_HEAP',
         24: 'ZEROED_DATA_HEAP', 25: 'MAIN'}
# (struct format, is_relative) for import entry types
IMPORTS = {IET_REL_I8: ('<b', 1), IET_IMM_U8: ('<B', 0), IET_REL_I16: ('<h', 2),
           IET_IMM_U16: ('<H', 0), IET_REL_I32: ('<i', 4), IET_IMM_U32: ('<I', 0),
           IET_REL_I64: ('<q', 8), IET_IMM_I64: ('<Q', 0)}

def die(msg):
    sys.exit(f'binlink: error: {msg}')

data = open(sys.argv[1], 'rb').read()
hdr = 0x20
patch_off = struct.unpack_from('<Q', data, 0x10)[0]
code = bytearray(data[hdr:patch_off])
p, syms, imports, abss, cur = patch_off, {}, [], [], None
while data[p]:
    et = data[p]; i = struct.unpack_from('<I', data, p + 1)[0]; p += 5
    off = 0
    if IET_REL_I0 <= et <= IET_REL_RISCV:  # imports carry an extra I32 addend
        off = struct.unpack_from('<i', data, p)[0]; p += 4
    e = data.index(b'\0', p); name = data[p:e].decode(); p = e + 1
    if et in (IET_REL32_EXPORT, IET_IMM32_EXPORT, IET_REL64_EXPORT, IET_IMM64_EXPORT):
        syms[name] = (i, et in (IET_IMM32_EXPORT, IET_IMM64_EXPORT))
    elif et in IMPORTS:
        if name:
            cur = name  # an empty name reuses the previous symbol
        if cur is None:
            die(f'import entry at patch offset {p:#x} has no symbol name')
        imports.append((et, i, off, cur))
    elif et == IET_ABS_ADDR:  # i offsets follow; each U64 there gets += module base
        for _ in range(i):
            abss.append(struct.unpack_from('<I', data, p)[0]); p += 4
    else:
        die(f'unsupported patch table entry {NAMES.get(et, et)} (type {et}) '
            f'name {name!r}; no heap/top-level code exists in the kernel yet')

def addr(name, ctx):
    if name not in syms:
        die(f'unresolved import "{name}" (needed by {ctx}); the kernel must define it')
    v, imm = syms[name]
    return v if imm else ORG + v

for off in abss:
    struct.pack_into('<Q', code, off, struct.unpack_from('<Q', code, off)[0] + ORG)
for et, at, add, name in imports:
    fmt, rel = IMPORTS[et]
    v = addr(name, f'patch at code offset {at:#x}') + add
    if rel:
        v = v - (ORG + at) - rel
    try:
        struct.pack_into(fmt, code, at, v)
    except struct.error:
        die(f'patch value {v:#x} for "{name}" does not fit type {et}')
if 'KMain' not in syms:
    die('KMain is not defined')
open(sys.argv[2], 'wb').write(code)
print('exports', {k: hex(ORG + v[0]) for k, v in syms.items()})
open(sys.argv[3], 'w').write(f'KMAIN = {addr("KMain", "boot"):#x};\n')
