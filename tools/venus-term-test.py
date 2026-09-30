#!/usr/bin/env python3
"""Five established terminal screens rendered through Venus and compared with CPU pixels."""
import importlib.util
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'build/venus-term-test'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


vim = module('vim_test', ROOT / 'tools/vim-test.py')
verify = module('kernel_verify', ROOT / 'tools/kernel-verify.py')
vim.KEYS[' '] = (57, False)
vim.KEYS['|'] = (43, True)
START = {'resize': (1024, 768)}  # the boot size, when the screen is resized
PROBE = vim.typed('Print("VENUS%d %d\\n",1,fb.venus); FbCursorHide; FbFlush; '
                  'I64 vr=fb.venus_rows,vb=fb.venus_cell_bytes,vf=fb.venus_frames; '
                  'Print("direct cells%d\\n",1); FbFlush; '
                  'Print("DIRTY%d %d %d %d %d\\n",1,fb.venus_rows-vr,fb.venus_cell_bytes-vb,fb.venus_frames-vf,fb.cols); '
                  'FbCursorShow; ConsClear;\n')

def line(s):
    return vim.typed(s + '\n')


def prefix(ch):  # Tmux: Ctrl+B, then ch
    return '1 29 1\n' + vim.keys_of(48) + '1 29 0\n' + vim.typed(ch)


def disk_image(d):
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'VENUS', '::'], check=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([str(ROOT/'tools/venus/install.sh'),str(disk)],check=True)
    return disk


def run(d, mode, script, size, disk):
    size = START.get(d.name, size)
    args = [str(ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm')), '--headless', '--cpus', '2', '--mem', '1024', '--timeout', '120',
            '--width', str(size[0]), '--height', str(size[1]), '--input-script', str(d / 'input.txt'),
            '--screenshot', str(d / f'{mode}.png')]
    if mode == 'cpu':
        args.append('--no-venus')
    if disk:
        args += ['--disk', str(disk)]
    with (d / f'{mode}.log').open('wb') as out:
        subprocess.run(args + [sys.argv[1]], stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, check=True)
    log = (d / f'{mode}.log').read_text(errors='replace')
    marker=f'VENUS1 {int(mode == "venus")}'
    assert marker in log.splitlines(), f'{d}/{mode}.log: wrong renderer'
    assert not any(x in log.split('Cool shell:',1)[-1] for x in ['ERROR:','VENUS FAIL','compiler exited','unavailable']), f'{d}/{mode}.log: guest failed'
    if mode == 'venus':
        m=re.search(r'^DIRTY1 (\d+) (\d+) (\d+) (\d+)$',log,re.M)
        assert m, f'{d}: missing cell-write counters'
        rows,byte_count,frames,cols=map(int,m.groups())
        assert 0<rows<=2 and byte_count==rows*cols*16 and 0<=frames<=1, (rows,byte_count,frames,cols)
    return verify.read_png(d / f'{mode}.png')


def compare(name, script, size=(1024, 768), tolerance=0.001, pixels=()):
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    (d / 'input.txt').write_text(vim.BOOT + PROBE + script + 'delay 300\nquit\n')
    image = disk_image(d)
    gpu = run(d, 'venus', script, size, image)
    cpu = run(d, 'cpu', script, size, image)
    assert gpu[:2] == cpu[:2] == size, f'{name}: sizes {gpu[:2]} {cpu[:2]}'  # after any resize
    differ = sum(1 for a, b in zip(gpu[2], cpu[2]) if a != b for x in range(size[0])
                 if a[3 * x:3 * x + 3] != b[3 * x:3 * x + 3])
    share = differ / (size[0] * size[1])
    assert share <= tolerance, f'{name}: {differ} pixels differ ({share:.4%}); see {d}'
    for x, y, rgb in pixels:  # pixel drawing (FbFillRect) shows through Vulkan
        got = tuple(gpu[2][y][3 * x:3 * x + 3])
        assert got == rgb, f'{name}: pixel {x},{y} is {got} with Vulkan, expected {rgb}; see {d}'
    print(f'venus-term-test: {name} {size[0]}x{size[1]}: {differ} pixels differ ({share:.4%})', flush=True)


def resident_and_fallback():
    d=OUT/'lifecycle'; d.mkdir(parents=True,exist_ok=True)
    disk=d/'disk.img'
    with disk.open('wb') as f: f.truncate(64<<20)
    subprocess.run(['mformat','-i',str(disk),'-F','::'],check=True)
    subprocess.run([str(ROOT/'tools/venus/install.sh'),str(disk)],check=True)
    for cpus in [1,2]:
        script=(vim.BOOT+vim.typed('exit\n')+vim.BOOT+vim.typed('Exit();\n')+vim.BOOT+
                vim.typed('Print("LIFE%d %d %d\\n",1,fb.venus,fb.venus_frames);\n')+vim.finish('LIFE1 1'))
        inp=d/f'{cpus}.input'; inp.write_text(script)
        log=d/f'{cpus}.log'
        with log.open('wb') as f:
            proc=subprocess.run([str(ROOT/'build/coolvm-venus'),'--headless','--cpus',str(cpus),
                '--mem','1024','--timeout','45','--disk',str(disk),'--input-script',str(inp),sys.argv[1]],
                stdout=f,stderr=subprocess.STDOUT,timeout=50)
        text=log.read_text(errors='replace').split('SELFTEST PASS',1)[-1]
        assert proc.returncode==0 and text.count('Cool shell:')==3 and text.count('VENUS TERMINAL READY')==1
        assert 'LIFE1 1' in text and not any(x in text for x in ['ERROR:','VENUS FAIL','compiler exited'])
        print(f'venus-term-test: resident across two shell restarts, {cpus} CPU PASS',flush=True)
    # The real renderer remains advertised, but a missing shader must keep CPU.
    subprocess.run(['mdel','-i',str(disk),'::Vulkan/terminal.frag.spv'],check=True)
    inp=d/'fallback.input'
    inp.write_text(vim.BOOT+vim.typed('Print("FALL%d %d %d\\n",1,fb.venus,gpu.venus_features);\n')+vim.finish('FALL1 0 1'))
    log=d/'fallback.log'
    with log.open('wb') as f:
        proc=subprocess.run([str(ROOT/'build/coolvm-venus'),'--headless','--cpus','2','--mem','1024',
            '--timeout','30','--disk',str(disk),'--input-script',str(inp),sys.argv[1]],stdout=f,stderr=subprocess.STDOUT,timeout=35)
    text=log.read_text(errors='replace')
    assert proc.returncode==0 and 'FALL1 0 1' in text and 'VENUS TERMINAL READY' not in text and 'ERROR:' not in text
    print('venus-term-test: missing shader falls back to CPU PASS',flush=True)


colors = ('ConsClear; I64 i; for (i = 0; i < 16; i++) Print("\\e[%dm color %d \\e[0m", 30 + i % 8, i); '
          'for (i = 0; i < 16; i++) Print("\\e[48;5;%dm %d \\e[0m", 16 + i * 13, i); '
          'Print("\\n\\e[7mreverse\\e[0m \\e[1mbold\\e[0m \\e[38;2;10;200;30mrgb\\e[0m\\n"); '
          'for (i = 0; i < 70; i++) Print("scroll %d abcdefghijklmnopqrstuvwxyz\\n", i); '
          'Print("\\xed\\x95\\x9c\\xea\\xb8\\x80 \\xed\\x85\\x8c\\xec\\x8a\\xa4\\xed\\x8a\\xb8 wide '
          '\\xe6\\xbc\\xa2\\xe5\\xad\\x97 \\e[1;33m\\xec\\x83\\x89\\e[0m END%d\\n", 1); '
          'FbFillRect(40, 30, 90, 50, 0x3060C0);')
compare('colors', line(colors) + 'wait END1\n', pixels=[(40, 30, (0x30, 0x60, 0xC0)), (129, 79, (0x30, 0x60, 0xC0))])
compare('margins', line(colors) + 'wait END1\n', size=(1031, 775))
compare('vim', line('Vim("C:/Init.cool");') + 'delay 1500\n' + vim.typed('jjjwww') + 'delay 500\n')
compare('tmux', 'delay 2000\n' + line('Tmux;') + 'delay 1500\n' + prefix('%') + 'delay 1000\n' +
        line('Print("\\e[32mright pane %d\\e[0m\\n", 42);') + 'delay 300\n' + prefix('o') +
        line('Print("\\xed\\x95\\x9c\\xea\\xb8\\x80 left %d\\n", 7);') + 'delay 800\n')
compare('resize', line('ConsClear; Print("before %d\\n", 1);') + 'wait before 1\nresize 800 600\ndelay 800\n' +
        line('Print("after %d\\n", 2);') + 'wait after 2\n', size=(800, 600))
resident_and_fallback()
print('venus-term-test: PASS')
