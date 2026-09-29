import struct, sys
# Relocates an Aiwnios AOT BIN to ORG and resolves its patch table.
# Patch table semantics follow Aiwnios c/loader.c and Src/KLoadARM.HC.
#
# Output image layout (starting at ORG):
#   code | main table (U64 addrs of top-level code, 0-terminated) | initialized globals
# followed by the zero-filled globals, which are not stored in the image:
#   KBSS_START .. KBSS_END, cleared by Boot.S.
# Usage: binlink.py <in.BIN> <out.raw> <out syms.ld> [arch.syms]
# arch.syms (`nm` output of the linked assembly) resolves HolyC `import`s of
# assembly routines; every HolyC export is written to syms.ld as HC_<name>.
ORG = 0x40100000  # must match os/Kernel/Kernel.ld

IET_REL_I8, IET_IMM_U8, IET_REL_I16, IET_IMM_U16 = 4, 5, 6, 7
IET_REL_I32, IET_IMM_U32, IET_REL_I64, IET_IMM_I64 = 8, 9, 10, 11
IET_REL_I0, IET_REL_RISCV = 2, 12
IET_REL32_EXPORT, IET_IMM32_EXPORT, IET_REL64_EXPORT, IET_IMM64_EXPORT = 16, 17, 18, 19
IET_ABS_ADDR = 20
IET_DATA_HEAP, IET_ZEROED_DATA_HEAP = 23, 24
IET_MAIN = 25
NAMES = {21: 'CODE_HEAP', 22: 'ZEROED_CODE_HEAP'}
# (struct format, is_relative) for import entry types
IMPORTS = {IET_REL_I8: ('<b', 1), IET_IMM_U8: ('<B', 0), IET_REL_I16: ('<h', 2),
           IET_IMM_U16: ('<H', 0), IET_REL_I32: ('<i', 4), IET_IMM_U32: ('<I', 0),
           IET_REL_I64: ('<q', 8), IET_IMM_I64: ('<Q', 0)}

def die(msg):
    sys.exit(f'binlink: error: {msg}')

def align(n, a=16):
    return (n + a - 1) & -a

data = open(sys.argv[1], 'rb').read()
hdr = 0x20
patch_off = struct.unpack_from('<Q', data, 0x10)[0]
code = bytearray(data[hdr:patch_off])
syms = {}      # name -> (value, is_absolute)
imports, abss, mains, globs = [], [], [], []
p, cur = patch_off, None
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
    elif et in (IET_DATA_HEAP, IET_ZEROED_DATA_HEAP):
        # I64 size, U8 init[size], then i x {I32 patch_at, I32 addend}:
        # the U64 at patch_at becomes (address of the global + addend).
        size = struct.unpack_from('<q', data, p)[0]; p += 8
        init = data[p:p + size]; p += size
        refs = [struct.unpack_from('<ii', data, p + 8 * k) for k in range(i)]; p += 8 * i
        globs.append((name, init, refs))
    elif et == IET_MAIN:  # top-level code (global initializers etc.) at code offset i
        mains.append(i)
    else:
        die(f'unsupported patch table entry {NAMES.get(et, et)} (type {et}) name {name!r}')

# Lay out the main table and the globals.
image = code + bytes(align(len(code)) - len(code))
main_table = ORG + len(image)
for m in mains:
    image += struct.pack('<Q', ORG + m)
image += struct.pack('<Q', 0)
zeroed = []
for name, init, refs in globs:
    if any(init):
        image += bytes(align(len(image)) - len(image))
        at = ORG + len(image)
        image += init
    else:
        zeroed.append((name, init, refs))
        continue
    if name:
        syms[name] = (at, True)
    for patch_at, add in refs:
        struct.pack_into('<Q', image, patch_at, at + add)
image += bytes(align(len(image)) - len(image))
kbss_start = kbss = ORG + len(image)
for name, init, refs in zeroed:
    kbss = align(kbss)
    if name:
        syms[name] = (kbss, True)
    for patch_at, add in refs:
        struct.pack_into('<Q', image, patch_at, kbss + add)
    kbss += len(init)
kbss_end = align(kbss)

arch_names = set()
if len(sys.argv) > 4:
    for line in open(sys.argv[4]):
        f = line.split()
        if len(f) == 3 and f[1] in 'TtDdBb' and f[2] not in syms:
            syms[f[2]] = (int(f[0], 16), True)
            arch_names.add(f[2])

def addr(name, ctx):
    if name not in syms:
        die(f'unresolved import "{name}" (needed by {ctx}); the kernel must define it')
    v, absolute = syms[name]
    return v if absolute else ORG + v

for off in abss:
    struct.pack_into('<Q', image, off, struct.unpack_from('<Q', image, off)[0] + ORG)
for et, at, add, name in imports:
    fmt, rel = IMPORTS[et]
    v = addr(name, f'patch at code offset {at:#x}') + add
    if rel:
        v = v - (ORG + at) - rel
    try:
        struct.pack_into(fmt, image, at, v)
    except struct.error:
        die(f'patch value {v:#x} for "{name}" does not fit type {et}')
if 'KMain' not in syms:
    die('KMain is not defined')

open(sys.argv[2], 'wb').write(image)
open(sys.argv[3], 'w').write(
    ''.join(f'HC_{k} = {addr(k, "export"):#x};\n' for k in sorted(syms)
            if k.isidentifier() and k not in arch_names) +
    f'KMAIN = {addr("KMain", "boot"):#x};\n'
    f'MAIN_TABLE = {main_table:#x};\n'
    f'KBSS_START = {kbss_start:#x};\n'
    f'KBSS_END = {kbss_end:#x};\n')
print(f'binlink: code {len(code):#x} bytes, {len(mains)} init chunks, '
      f'{len(globs) - len(zeroed)} data + {len(zeroed)} zeroed globals, '
      f'image {ORG:#x}..{kbss_end:#x}')
