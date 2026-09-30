#!/usr/bin/env python3
"""Console fonts (os/Kernel/Glyph.cool), on the CPU renderer and, when the Venus stack is
built, on the Vulkan terminal:
- at 2x, Unifont must be the 1x screen with every pixel doubled;
- a TrueType smoke test (skipped without Sarasa Mono K in ~/Library/Fonts): FontSet loads
  it, the cell metrics are sane at 1x and 2x, and a Latin + Hangul line is drawn with
  antialiased (gray) pixels in every glyph.
Artifacts under build/font-test/."""
import importlib.util
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/font-test'
KERNEL = sys.argv[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


vim = module('vim_test', ROOT / 'tools/vim-test.py')
verify = module('kernel_verify', ROOT / 'tools/kernel-verify.py')
# The Makefile passes --venus when the Venus stack is installed, after rebuilding the
# monitor and the terminal's shaders (files left over from an older build would be stale).
VENUS = '--venus' in sys.argv[2:]


SARASA = pathlib.Path.home() / 'Library/Fonts/SarasaMonoK-Regular.ttf'


def disk_image(venus, fonts=False):
    disk = OUT / (('venus' if venus else 'disk') + ('-fonts' if fonts else '') + '.img')
    if not disk.exists():
        with disk.open('wb') as f:
            f.truncate((160 if fonts else 64) * 1024 * 1024)
        subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'FONTS', '::'], check=True)
        subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True, stdout=subprocess.DEVNULL)
        if fonts:
            subprocess.run([str(ROOT / 'tools/disk-fonts.sh'), str(disk)], check=True, stdout=subprocess.DEVNULL)
        if venus:
            subprocess.run([str(ROOT / 'tools/venus/install.sh'), str(disk)], check=True)
    return disk


def boot(name, venus, script, size, scale, fonts=False):
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / 'input.txt').write_text(vim.BOOT + script + 'delay 300\nquit\n')
    vm = ROOT / ('build/coolvm-venus' if venus else 'build/coolvm')
    args = [str(vm), '--headless', '--cpus', '2', '--mem', '1024', '--timeout', '60',
            '--width', str(size[0]), '--height', str(size[1]), '--scale', str(scale),
            '--input-script', str(d / 'input.txt'), '--screenshot', str(d / 'screen.png'),
            '--disk', str(disk_image(venus, fonts))]
    if not venus:
        args.append('--no-venus')
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(args + [KERNEL], stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert ('VENUS TERMINAL READY' in log) == venus, f'{d}/vm.log: wrong renderer'
    assert 'ERROR:' not in log.split('Cool shell:', 1)[-1], f'{d}/vm.log: guest error'
    return verify.read_png(d / 'screen.png'), log


SCENE = vim.typed(
    'ConsClear; I64 i; for (i = 0; i < 8; i++) Print("\\e[%dm color %d \\e[0m", 31 + i % 7, i); '
    'Print("\\n\\e[7mreverse\\e[0m \\e[1mbold\\e[0m\\n"); '
    'for (i = 0; i < 60; i++) Print("scroll %d abcdefghijklmnopqrstuvwxyz\\n", i); '
    'Print("\\xed\\x95\\x9c\\xea\\xb8\\x80 wide END%d\\n", 1); '
    'FbFillRect(40 * font.scale, 30 * font.scale, 90 * font.scale, 50 * font.scale, 0x3060C0);\n') + 'wait END1\n'


def hidpi(venus):
    mode = 'venus' if venus else 'cpu'
    (w1, h1, one), _ = boot(f'hidpi-{mode}-1x', venus, SCENE, (1024, 768), 1)
    (w2, h2, two), log = boot(f'hidpi-{mode}-2x', venus, SCENE, (2048, 1536), 2)
    assert (w2, h2) == (2 * w1, 2 * h1)
    for y in range(h1):
        doubled = bytearray()
        for x in range(w1):
            doubled += one[y][3 * x:3 * x + 3] * 2
        assert two[2 * y] == doubled and two[2 * y + 1] == doubled, f'hidpi {mode}: row {y} is not the 1x row doubled'
    print(f'font-test: 2x Unifont equals 1x doubled ({mode})', flush=True)


# Init.cool sets Sarasa 14 when C:/Fonts has it; the line is drawn at the top-left.
TTF = vim.typed('Print("FONT%d %d %d %d %d\\n", 1, font.cfg.face != NULL, font.cfg.bold != NULL, font.cw, font.ch); '
                'ConsClear; Print("Hello \\xed\\x95\\x9c\\xea\\xb8\\x80 \\e[1mbold\\e[0m"); FbCursorHide; '
                'FbFlush; Sleep(100); Print("\\nEND%d\\n", 1);\n') + 'wait END1\n'


def ttf(venus, scale):
    mode = 'venus' if venus else 'cpu'
    size = (1024 * scale, 768 * scale)
    (w, h, rows), log = boot(f'ttf-{mode}-{scale}x', venus, TTF, size, scale, fonts=True)
    line = [l for l in log.splitlines() if l.startswith('FONT1 ')]
    assert line, f'ttf {mode}: no metrics line'
    face, bold, cw, ch = map(int, line[-1].split()[1:])
    assert face and bold, f'ttf {mode}: Sarasa not loaded ({line[-1]})'
    assert 4 * scale <= cw <= 12 * scale and 12 * scale <= ch <= 26 * scale and ch > cw, f'ttf {mode}: cell {cw}x{ch}'
    # "Hello 한글 bold": every glyph cell has ink, and the glyphs are antialiased.
    cells = [0, 1, 2, 3, 4, 6, 8, 11, 12, 13, 14]
    gray = 0
    for c in cells:
        ink = 0
        for y in range(ch):
            for x in range(c * cw, (c + (2 if c in (6, 8) else 1)) * cw):
                v = max(rows[y][3 * x:3 * x + 3])
                ink += v > 0
                gray += 0 < v < 255
        assert ink, f'ttf {mode} {scale}x: cell {c} of the text line is empty; see {OUT}'
    assert gray, f'ttf {mode}: no antialiased pixels (not a TTF glyph?)'
    print(f'font-test: Sarasa {cw}x{ch} cells at {scale}x, Latin, Hangul and bold drawn ({mode})', flush=True)
    return cw, ch


OUT.mkdir(parents=True, exist_ok=True)
for f in OUT.glob('*.img'):
    f.unlink()
hidpi(False)
if VENUS:
    hidpi(True)
else:
    print('font-test: Venus stack not installed, Vulkan terminal skipped (make venus-vendor)')
if SARASA.exists():
    one = ttf(False, 1)
    two = ttf(False, 2)
    assert abs(two[0] - 2 * one[0]) <= 1 and abs(two[1] - 2 * one[1]) <= 1, f'2x cells {two} vs 1x {one}'
    if VENUS:
        ttf(True, 1)
else:
    print(f'font-test: {SARASA} not found, TrueType test skipped')
print('font-test: PASS')
