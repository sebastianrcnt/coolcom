#!/usr/bin/env python3
"""Compare six upstream stbtt glyph bitmaps with native Cool byte for byte."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/stbtt-test'
VENDOR = ROOT / 'vendor'
ASSETS = (
    ('stb/stb_truetype.h',
     'https://raw.githubusercontent.com/nothings/stb/2c980bb59875b0d32144a71867fbdebb2f77cd20/stb_truetype.h',
     'ecd30b05e0dd4fea3a13c26810dd9e1992dc379049482c393d5a19e6b5090aab'),
    ('fonts/NotoSansKR.ttf',
     'https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanskr/NotoSansKR%5Bwght%5D.ttf',
     '194018e6b2b293a7964f037b25c0249ce1418bc9ab3c971060a03aa57861e252'),
    ('fonts/OFL.txt',
     'https://raw.githubusercontent.com/google/fonts/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl/notosanskr/OFL.txt',
     None),
)
CODEPOINTS = (65, 103, 90, 44032, 45208, 54620)


def run(*args, env=None):
    result = subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                            text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}):\n'
                           f'{result.stdout[-3000:]}\n{result.stderr[-3000:]}')
    return result


def fetch_assets():
    for name, url, digest in ASSETS:
        path = VENDOR / name
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(urlopen(url, timeout=60).read())
        if digest and hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'vendor asset has an unexpected SHA-256: {path}')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    fetch_assets()
    run(sys.executable, 'tools/c2hc/stbtt_prepare.py', str(OUT))
    generated = OUT / 'StbTrueType.HC'
    run(sys.executable, 'tools/c2hc/c2hc.py', '--root', 'stbtt_InitFont',
        '--root', 'stbtt_MakeCodepointBitmap',
        str(OUT / 'stbtt_ttf.c'), str(generated))
    formatted = OUT / 'StbTrueType.formatted.HC'
    run('build/coolc', '--format', 'build/hcfmt.BIN',
        str(generated), str(formatted))
    committed = ROOT / 'coolc/Lib/StbTrueType.HC'
    if formatted.read_bytes() != committed.read_bytes():
        raise RuntimeError('coolc/Lib/StbTrueType.HC differs from generated output')
    run('clang', '-std=c11', '-O0', 'tools/c2hc/stbtt_reference.c',
        '-lm', '-o', str(OUT / 'reference'))
    run(str(OUT / 'reference'))
    env = os.environ.copy()
    env['COOLC_COMPILER_BIN'] = str(ROOT / 'coolc/seed/Compiler.BIN')
    compiled = run('build/coolc', 'tools/c2hc/stbtt_driver.HC',
                   str(OUT / 'driver.BIN'), env=env)
    if 'Errs:0 ' not in compiled.stdout:
        raise RuntimeError(f'Cool compiler reported errors:\n{compiled.stdout[-3000:]}')
    run('build/coolc', '--run', str(OUT / 'driver.BIN'))
    c_bitmap = (OUT / 'clang.bin').read_bytes()
    cool_bitmap = (OUT / 'cool.bin').read_bytes()
    expected = len(CODEPOINTS) * 64 * 64
    if len(c_bitmap) != expected or len(cool_bitmap) != expected:
        raise RuntimeError('bitmap output has the wrong size')
    for index, codepoint in enumerate(CODEPOINTS):
        start = index * 4096
        c_glyph = c_bitmap[start:start + 4096]
        cool_glyph = cool_bitmap[start:start + 4096]
        if not any(c_glyph):
            raise RuntimeError(f'U+{codepoint:04X} produced an empty reference bitmap')
        if c_glyph != cool_glyph:
            differences = sum(a != b for a, b in zip(c_glyph, cool_glyph))
            raise RuntimeError(f'U+{codepoint:04X}: {differences} bitmap bytes differ')
        print(f'PASS U+{codepoint:04X} ({len(c_glyph)} bytes)')
    print(f'{expected} bitmap bytes match clang and native Cool')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
