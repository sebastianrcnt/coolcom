#!/usr/bin/env python3
"""Console fonts (os/Kernel/Glyph.cool): at 2x, Unifont must be the 1x screen with every
pixel doubled, on the CPU renderer and, when the Venus stack is built, on the Vulkan
terminal. Artifacts under build/font-test/."""
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
VENUS = (ROOT / 'build/coolvm-venus').exists() and all(
    (ROOT / 'build/venus' / f).exists() for f in ('Vulkan.cool', 'terminal.vert.spv', 'terminal.frag.spv'))


def disk_image(venus):
    disk = OUT / ('venus.img' if venus else 'disk.img')
    if not disk.exists():
        with disk.open('wb') as f:
            f.truncate(64 * 1024 * 1024)
        subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'FONTS', '::'], check=True)
        subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True, stdout=subprocess.DEVNULL)
        if venus:
            subprocess.run([str(ROOT / 'tools/venus/install.sh'), str(disk)], check=True)
    return disk


def boot(name, venus, script, size, scale):
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / 'input.txt').write_text(vim.BOOT + script + 'delay 300\nquit\n')
    vm = ROOT / ('build/coolvm-venus' if venus else 'build/coolvm')
    args = [str(vm), '--headless', '--cpus', '2', '--mem', '1024', '--timeout', '60',
            '--width', str(size[0]), '--height', str(size[1]), '--scale', str(scale),
            '--input-script', str(d / 'input.txt'), '--screenshot', str(d / 'screen.png'),
            '--disk', str(disk_image(venus))]
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


OUT.mkdir(parents=True, exist_ok=True)
for f in OUT.glob('*.img'):
    f.unlink()
hidpi(False)
if VENUS:
    hidpi(True)
else:
    print('font-test: Venus stack not built, Vulkan terminal skipped (make venus-vendor venus-terminal)')
print('font-test: PASS')
