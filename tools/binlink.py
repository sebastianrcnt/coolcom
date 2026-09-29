import struct, sys
# Relocates an Aiwnios AOT BIN to ORG and resolves its patch table.
# Patch table semantics follow Aiwnios c/loader.c and Src/KLoadARM.HC.
#
# Output image layout (starting at ORG):
#   code | main table (U64 addrs of top-level code, 0-terminated) | initialized globals
#   | relocation table (see below)
# followed by the zero-filled globals, which are not stored in the image:
#   KBSS_START .. KBSS_END, cleared by Boot.S.
#
# Symbol table (KSYM_TABLE in syms.ld), after the relocation table: every
# export and assembly symbol, sorted by address, for the shell (which registers
# them all) and for FunSeg (address -> name+offset). Addresses are stored
# relative to the table itself, so it needs no relocation:
#   U64 count | count x {I64 addr - table, U32 name offset from table, U32 kind}
#   | NUL-terminated names.  kind: 1 HolyC code, 2 HolyC data, 3 assembly.
#
# Relocation table (RELOC_TABLE in syms.ld). The Image is linked at a fixed
# base but m1n1 may load it at another 2 MiB-aligned address. Every place in
# the module that holds an absolute address is recorded exactly, so Boot.S can
# add (load base - link base) to those U64s and nothing else:
#   U64 link-time module base (ORG) | U32 count | U32 pad | U32 site[count]
# Each site is a byte offset from the module start of an 8-byte aligned U64.
# The assembly is position independent (adrp/add), so it needs no entries;
# tools/reloc-check.py proves that for the linked ELF and the final Image.
# Usage: binlink.py [--org ADDR] [--prelude FILE] <in.BIN> <out.raw> <out syms.ld> [arch.syms]
# --prelude appends FILE, NUL-terminated, after the symbol table (SHELL_PRELUDE:
# the shell prelude text, too big for the boot stub's pc-relative reach).
# arch.syms (`nm` output of the linked assembly) resolves HolyC `import`s of
# assembly routines; every HolyC export is written to syms.ld as HC_<name>.
ORG = 0x800400000  # module link address (MODULE_BASE in Kernel.ld); --org overrides
args = sys.argv[1:]
if args[:1] == ['--org']:
    ORG = int(args[1], 0)
    args = args[2:]
prelude = b''
if args[:1] == ['--prelude']:
    prelude = open(args[1], 'rb').read() + b'\0'
    args = args[2:]

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

data = open(args[0], 'rb').read()
hdr = 0x20
patch_off = struct.unpack_from('<Q', data, 0x10)[0]
code = bytearray(data[hdr:patch_off])
syms = {}      # name -> (value, kind): kind REL = code offset, ADDR = absolute address, CONST = plain number
REL, ADDR, CONST = 'rel', 'addr', 'const'
imports, abss, mains, globs = [], [], [], []
p, cur = patch_off, None
while data[p]:
    et = data[p]; i = struct.unpack_from('<I', data, p + 1)[0]; p += 5
    off = 0
    if IET_REL_I0 <= et <= IET_REL_RISCV:  # imports carry an extra I32 addend
        off = struct.unpack_from('<i', data, p)[0]; p += 4
    e = data.index(b'\0', p); name = data[p:e].decode(); p = e + 1
    if et in (IET_REL32_EXPORT, IET_IMM32_EXPORT, IET_REL64_EXPORT, IET_IMM64_EXPORT):
        syms[name] = (i, CONST if et in (IET_IMM32_EXPORT, IET_IMM64_EXPORT) else REL)
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

arch_names = set()
if len(args) > 3:
    for line in open(args[3]):
        f = line.split()
        if len(f) == 3 and f[1] in 'TtDdBb' and f[2] not in syms:
            syms[f[2]] = (int(f[0], 16), ADDR)
            arch_names.add(f[2])

# Lay out the main table and the globals.
sites = {}  # image offset of an absolute U64 -> what put it there

def site(off, what):
    if off & 7 or off < 0:
        die(f'absolute address site at image offset {off:#x} ({what}) is not 8-byte aligned; '
            'Boot.S relocates with aligned 64-bit accesses')
    if off in sites:
        die(f'image offset {off:#x} is patched twice ({sites[off]} and {what})')
    sites[off] = what

image = code + bytes(align(len(code)) - len(code))
main_table = ORG + len(image)
for k, m in enumerate(mains):
    site(len(image), 'main table')
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
        syms[name] = (at, ADDR)
    for patch_at, add in refs:
        struct.pack_into('<Q', image, patch_at, at + add)
for off in abss:
    site(off, 'IET_ABS_ADDR')
for name, init, refs in globs:
    for patch_at, add in refs:
        site(patch_at, f'reference to global {name!r}')

def addr(name, ctx):
    if name not in syms:
        die(f'unresolved import "{name}" (needed by {ctx}); the kernel must define it')
    v, kind = syms[name]
    return v if kind != REL else ORG + v

# Imports of addresses stored as absolute values are relocation sites too.
# Only symbols that are addresses count: IMM exports are plain numbers, and
# globals (even zeroed ones, laid out below) are addresses.
addr_kind = {n: syms[n][1] for n in syms}
addr_kind.update({n: ADDR for n, _, _ in globs if n})
for et, at, add, name in imports:
    if et not in IMPORTS or IMPORTS[et][1] or addr_kind.get(name, CONST) == CONST:
        continue  # PC-relative, or a constant, or unresolved (reported later)
    if et != IET_IMM_I64:
        die(f'import "{name}" at code offset {at:#x} stores an address in a type-{et} field '
            'that cannot be relocated')
    site(at, f'import of {name!r}')

# The relocation table follows the initialized data, then the zeroed globals.
image += bytes(align(len(image), 8) - len(image))
reloc_table = ORG + len(image)
image += struct.pack('<QII', ORG, len(sites), 0)
image += b''.join(struct.pack('<I', off) for off in sorted(sites))
image += bytes(align(len(image), 8) - len(image))
glob_names = {n for n, _, _ in globs if n}
ksym_names = sorted(n for n in set(syms) | glob_names
                    if n.isidentifier() and (n in glob_names or syms[n][1] != CONST))
ksym_table = ORG + len(image)
pool = b''.join(n.encode() + b'\0' for n in ksym_names)
ksym_at = len(image)
image += bytes(8 + 16 * len(ksym_names)) + pool
shell_prelude = ORG + len(image)
image += prelude
image += bytes(align(len(image)) - len(image))
kbss_start = kbss = ORG + len(image)
for name, init, refs in zeroed:
    kbss = align(kbss)
    if name:
        syms[name] = (kbss, ADDR)
    for patch_at, add in refs:
        struct.pack_into('<Q', image, patch_at, kbss + add)
    kbss += len(init)
kbss_end = align(kbss)

ksyms, name_off = [], 8 + 16 * len(ksym_names)
for n in ksym_names:
    kind = 3 if n in arch_names else 2 if n in glob_names or syms[n][1] == ADDR else 1
    ksyms.append((addr(n, 'symbol table'), name_off, kind))
    name_off += len(n) + 1
ksyms.sort()
struct.pack_into('<Q', image, ksym_at, len(ksyms))
for k, (a, off, kind) in enumerate(ksyms):
    struct.pack_into('<qII', image, ksym_at + 8 + 16 * k, a - ksym_table, off, kind)

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

open(args[1], 'wb').write(image)
open(args[2], 'w').write(
    ''.join(f'HC_{k} = {addr(k, "export"):#x};\n' for k in sorted(syms)
            if k.isidentifier() and k not in arch_names) +
    f'KMAIN = {addr("KMain", "boot"):#x};\n'
    f'MAIN_TABLE = {main_table:#x};\n'
    f'RELOC_TABLE = {reloc_table:#x};\n'
    f'KSYM_TABLE = {ksym_table:#x};\n'
    f'SHELL_PRELUDE = {shell_prelude:#x};\n'
    f'KBSS_START = {kbss_start:#x};\n'
    f'KBSS_END = {kbss_end:#x};\n')
print(f'binlink: code {len(code):#x} bytes, {len(mains)} init chunks, '
      f'{len(globs) - len(zeroed)} data + {len(zeroed)} zeroed globals, '
      f'{len(sites)} relocation sites, {len(ksyms)} symbols, image {ORG:#x}..{kbss_end:#x}')
