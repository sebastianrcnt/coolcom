#!/usr/bin/env python3
"""Package the kernel's assembly for MakeKernel, the in-OS kernel linker
(os/Kernel/MakeKernel.cool, docs/kernel-rebuild.md).

The OS has no assembler, so the assembly (Boot.S, Arch.S, Blob.S with the
compiler seed, FontData.S) is the one prebuilt part. Its input is a link of
the assembly alone like the Makefile's pass 1 (build/pre/stub.elf, linked
with -q so it keeps its relocations): the assembly at its final addresses
(they do not depend on the HolyC module; the Makefile checks that) with every
reference to the HolyC module and to what follows it pointing at a stand-in. MakeKernel copies
these bytes and re-applies the relocations with the real values.

  mkbootstub.py pre/stub.elf arch.syms out.BIN

out.BIN, all little-endian:
  U8  magic[8] "CoolStub"
  U64 image_base, module_base  (IMAGE_BASE, MODULE_BASE of Kernel.ld)
  U64 text_size                (stub bytes from image_base: .text and .data)
  U64 mmu_size                 (.mmutables, NOLOAD, placed after the font)
  U64 nrelocs, narch, pool_size
  U8  text[text_size], padded to 8
  nrelocs x {U32 at (from image_base), U32 type, I64 addend, I64 value, I64 name}
      name is a pool offset, or -1 for a symbol inside the stub whose value is
      final (value); named symbols are resolved by MakeKernel: HC_<export>,
      binlink's symbols (KMAIN, RELOC_TABLE, ...) and the layout after the
      module (.fontdata, .mmutables, image_end)
  narch x {I64 value, I64 name}   arch.syms in nm order (binlink.py's arch.syms)
  U8  pool[pool_size]             NUL-terminated names
"""
import struct
import sys

EXTERN = {'KMAIN', 'KTEXT_END', 'MAIN_TABLE', 'RELOC_TABLE', 'KSYM_TABLE', 'SHELL_PRELUDE',
          'ARM64_OPS', 'KBSS_START', 'KBSS_END'}
LAYOUT = {'.fontdata', '.mmutables', 'image_end'}
TYPES = {260: 'PREL64', 274: 'ADR_PREL_LO21', 275: 'ADR_PREL_PG_HI21', 277: 'ADD_ABS_LO12_NC',
         280: 'CONDBR19', 282: 'JUMP26', 283: 'CALL26'}


def die(msg):
    sys.exit(f'mkbootstub: error: {msg}')


elf_path, syms_path, out_path = sys.argv[1:4]
e = open(elf_path, 'rb').read()
if e[:4] != b'\x7fELF' or e[4] != 2:
    die(f'{elf_path} is not ELF64')
shoff, = struct.unpack_from('<Q', e, 0x28)
shentsize, shnum, shstrndx = struct.unpack_from('<HHH', e, 0x3a)
secs = []
for i in range(shnum):
    name, typ, flags, addr, off, size, link, info, align, entsize = struct.unpack_from(
        '<IIQQQQIIQQ', e, shoff + i * shentsize)
    secs.append(dict(name=name, type=typ, addr=addr, off=off, size=size, link=link, info=info))
shstr = secs[shstrndx]


def cstr(off):
    return e[off:e.index(b'\0', off)].decode()


for s in secs:
    s['name'] = cstr(shstr['off'] + s['name'])
by_name = {s['name']: s for s in secs}
text = by_name['.text']
image_base = text['addr']
mmu = by_name['.mmutables']
module_base = by_name['.fontdata']['addr']  # pass 1: KBSS_END stands at MODULE_BASE

# Stub bytes: every PROGBITS section below the module, gaps zero (objcopy -O binary).
stub = bytearray()
for s in secs:
    if s['type'] == 1 and s['addr'] and s['addr'] < module_base:
        at = s['addr'] - image_base
        if at < len(stub):
            die(f'section {s["name"]} overlaps')
        stub += bytes(at - len(stub)) + e[s['off']:s['off'] + s['size']]

symtab = by_name['.symtab']
strtab = secs[symtab['link']]


def sym(i):
    name, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', e, symtab['off'] + 24 * i)
    if (info & 15) == 3:  # STT_SECTION
        return secs[shndx]['name'], value, shndx
    return cstr(strtab['off'] + name), value, shndx


pool = bytearray(b'\0')
pool_at = {}


def intern(n):
    if n not in pool_at:
        pool_at[n] = len(pool)
        pool.extend(n.encode() + b'\0')
    return pool_at[n]


relocs = []
for s in secs:
    if s['type'] != 4:  # SHT_RELA
        continue
    target = secs[s['info']]
    if target['name'] != '.text':
        die(f'relocations in {target["name"]}: only .text is expected')
    for k in range(s['size'] // 24):
        off, info, addend = struct.unpack_from('<QQq', e, s['off'] + 24 * k)
        typ = info & 0xffffffff
        if typ not in TYPES:
            die(f'relocation type {typ} at {off:#x} is not handled by MakeKernel')
        n, v, shndx = sym(info >> 32)
        if n.startswith('HC_') or n in EXTERN or n in LAYOUT:
            name = intern(n)
        else:
            if v > module_base:
                die(f'{n} = {v:#x} lies past the stub but is not a known symbol')
            if shndx == 0xfff1 and n not in ('IMAGE_BASE', 'MODULE_BASE'):
                die(f'{n} is an absolute stand-in, not its linked value (link the stub '
                    'without stand-ins for linker-script symbols)')
            name = -1
        relocs.append((off - image_base, typ, addend, v, name))

arch = []
for line in open(syms_path):
    f = line.split()
    arch.append((int(f[0], 16), intern(f[2])))

out = bytearray(b'CoolStub')
out += struct.pack('<QQQQQQQ', image_base, module_base, len(stub), mmu['size'], len(relocs), len(arch), len(pool))
out += stub + bytes(-len(stub) % 8)
for r in relocs:
    out += struct.pack('<IIqqq', *r)
for a in arch:
    out += struct.pack('<qq', *a)
out += pool
open(out_path, 'wb').write(out)
print(f'mkbootstub: {len(stub):#x} stub bytes, {len(relocs)} relocations, {len(arch)} arch symbols')
