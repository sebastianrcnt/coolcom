#!/usr/bin/env python3
"""Build-time proof that the kernel Image relocates exactly (see os/Kernel/M1.md).

  reloc-check.py --elf cool.elf
      The assembly must be position independent: the linked ELF (linked with
      -q) may not contain absolute address relocations (R_AARCH64_ABS64/32/16,
      MOVW_UABS/SABS). The HolyC module is an opaque blob to the linker; its
      absolute addresses are the relocation table binlink.py emits.

  reloc-check.py --compare cool.elf kernel.Image alt.elf alt.Image
      Two Images of the same sources linked at different bases must be
      identical except for the 8-byte words listed in the relocation table,
      and each of those words (plus the table's own link-base word) must differ
      by exactly the base delta. A missed absolute address (in the module or in
      the assembly), an unlisted one, or a plain number that looks like one
      makes this fail.
"""
import re
import struct
import subprocess
import sys

ABS = re.compile(r'R_AARCH64_(ABS(64|32|16)|MOVW_[US]ABS_G\d\w*|P32_ABS\w*|P32_MOVW_[US]ABS\w*)$')


def die(msg):
    sys.exit(f'reloc-check: FAIL: {msg}')


def check_elf(elf):
    out = subprocess.run(['aarch64-elf-readelf', '-rW', elf], capture_output=True, text=True, check=True).stdout
    bad, total = [], 0
    section = ''
    for line in out.splitlines():
        if line.startswith('Relocation section'):
            section = line.split("'")[1]
            continue
        f = line.split()
        if len(f) >= 3 and re.fullmatch(r'[0-9a-f]{8,16}', f[0]) and f[2].startswith('R_AARCH64_'):
            total += 1
            if ABS.match(f[2]):
                bad.append(f'{section}: {line.strip()}')
    if bad:
        die(f'{elf} has {len(bad)} absolute relocation(s) not covered by the relocation table '
            '(use LA / adr in assembly):\n  ' + '\n  '.join(bad[:20]))
    print(f'reloc-check: {elf}: {total} relocations, none absolute')


def nm(elf):
    out = subprocess.run(['aarch64-elf-nm', elf], capture_output=True, text=True, check=True).stdout
    return {f[2]: int(f[0], 16) for f in map(str.split, out.splitlines()) if len(f) == 3}


def load(elf, img):
    s = nm(elf)
    data = open(img, 'rb').read()
    base = s['_start']
    tab = s['RELOC_TABLE'] - base
    link_base, count, _ = struct.unpack_from('<QII', data, tab)
    sites = list(struct.unpack_from(f'<{count}I', data, tab + 16))
    if sites != sorted(set(sites)):
        die(f'{elf}: relocation table is not sorted/unique')
    return s, data, base, tab, link_base, sites


def compare(elf_a, img_a, elf_b, img_b):
    sa, da, base_a, tab_a, lb_a, sites_a = load(elf_a, img_a)
    sb, db, base_b, tab_b, lb_b, sites_b = load(elf_b, img_b)
    delta = base_b - base_a
    if delta == 0 or delta & 0x1fffff:
        die(f'the two Images need different 2 MiB-aligned bases (delta {delta:#x})')
    if len(da) != len(db):
        die(f'Image sizes differ ({len(da):#x} vs {len(db):#x})')
    if lb_b - lb_a != delta or sites_a != sites_b:
        die('relocation table headers/sites differ between the two builds')
    mod = lb_a - base_a  # module start within the Image
    expect = {tab_a}  # the table's link-base word
    for off in sites_a:
        expect.add(mod + off)
    n = 0
    for w in sorted(expect):
        if w + 8 > len(da):
            die(f'relocation site at Image offset {w:#x} is beyond the Image')
        va, = struct.unpack_from('<Q', da, w)
        vb, = struct.unpack_from('<Q', db, w)
        if vb - va != delta:
            die(f'Image offset {w:#x} (link address {base_a + w:#x}) is in the relocation table but '
                f'{va:#x} -> {vb:#x} is not a {delta:#x} shift')
        if not base_a <= va <= sa['image_end']:
            die(f'relocation site at Image offset {w:#x} holds {va:#x}, outside the Image')
        n += 1
    skip = set()
    for w in expect:
        skip.update(range(w, w + 8))
    stray = [i for i in range(len(da)) if da[i] != db[i] and i not in skip]
    if stray:
        words = sorted({i & ~7 for i in stray})
        lines = []
        for w in words[:20]:
            va, = struct.unpack_from('<Q', da, w)
            vb, = struct.unpack_from('<Q', db, w)
            lines.append(f'Image offset {w:#x} (link address {base_a + w:#x}): {va:#x} vs {vb:#x}')
        die(f'{len(words)} word(s) depend on the load address but are not in the relocation table:\n  ' +
            '\n  '.join(lines))
    print(f'reloc-check: OK, {n - 1} sites; Images linked at {base_a:#x} and {base_b:#x} differ only there')


def main():
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == '--elf':
        check_elf(a[1])
    elif len(a) == 5 and a[0] == '--compare':
        compare(*a[1:])
    else:
        sys.exit(__doc__)


main()
