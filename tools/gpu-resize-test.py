#!/usr/bin/env python3
"""Headless display events: resource replacement, size notifications and modal reflow."""
import importlib.util
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj

vim = module('vim', ROOT / 'tools/vim-test.py')
verify = module('verify', ROOT / 'tools/kernel-verify.py')
OUT = ROOT / 'build/gpu-resize-test'
OUT.mkdir(parents=True, exist_ok=True)
font = verify.load_font()

def run(name, script, width, height, disk=None):
    d = OUT / name
    d.mkdir(exist_ok=True)
    (d / 'input.txt').write_text(script)
    args = ['build/coolvm', '--headless', '--no-logos', '--cpus', '2', '--mem', '1024', '--timeout', '35',
            '--width', '640', '--height', '480', '--input-script', str(d / 'input.txt'),
            '--screenshot', str(d / 'screen.png')]
    if disk:
        shutil.copyfile(disk, d / 'disk.img')
        args += ['--disk', str(d / 'disk.img')]
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(args + [sys.argv[1]], stdout=out, stderr=subprocess.STDOUT, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert 'ERROR:' not in log and 'Exception:' not in log, f'guest error: {d}/vm.log'
    w, h, rows = verify.read_png(d / 'screen.png')
    assert (w, h) == (width, height), f'{name}: screenshot {w}x{h}, expected {width}x{height}'
    return rows

def text(rows, row, label, fg=(255, 255, 255), bg=(0, 0, 0), col=0):
    bits = verify.draw_text(font, label, len(label))
    for y, line in enumerate(bits):
        for x, on in enumerate(line):
            # Ignore skipped bitmap alpha; read_png returns RGB.
            got = tuple(rows[row * 16 + y][(col * 8 + x) * 3:(col * 8 + x) * 3 + 3])
            assert got == (fg if on else bg), f'{label!r}: wrong pixel at row {row}, x {col*8+x}, y {y}: {got}'

# No keys arrive after READY: only resize events release the sleeping GetKey.
command = ('I64 i,ev,r,c; Print("READY%d\\n",1); for(i=1;i<=3;i++) {'
           'ev=GetKey; AnsiTermSize(&r,&c); AnsiClear; AnsiHome; '
           'Print("RESIZE%d %d %d %d\\n",i,r,c,ev==KEY_RESIZE); FbCursorHide; FbFlush;}')
script = vim.BOOT + vim.typed(command + '\n') + 'wait READY1\n'
for number, w, h in [(1, 800, 600), (2, 1280, 800), (3, 648, 496)]:
    script += f'resize {w} {h}\nwait RESIZE{number} {h//16} {w//8} 1\n'
rows = run('events', script + 'delay 250\nquit\n', 648, 496)
text(rows, 0, 'RESIZE3 31 81 1')

base = OUT / 'base.img'
with base.open('wb') as f:
    f.truncate(64 * 1024 * 1024)
subprocess.run(['mformat', '-i', str(base), '-F', '::'], check=True)
subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(base)], check=True)
source = OUT / 'resize.txt'
source.write_text('RESIZE-CONTENT\n' + ''.join(f'line {i:02d}\n' for i in range(1, 80)))
subprocess.run(['mcopy', '-o', '-i', str(base), str(source), '::resize.txt'], check=True)
for name, command, marker in [('vim', 'Vim("C:/resize.txt");', 'NORMAL C:/resize.txt'),
                               ('less', 'Less("C:/resize.txt");', 'q quit, space/b page'),
                               ('top', 'Top;', 'sort: cpu')]:
    # Repeated marker must come from the new redraw; it is not a typed command.
    script = vim.BOOT + vim.typed(command + '\n') + f'wait {marker}\nresize 800 600\nwait {marker}\ndelay 350\nquit\n'
    rows = run(name, script, 800, 600, base)
    if name == 'vim':
        # Cursor inverts the first cell; skip it in the content oracle.
        text(rows, 0, 'ESIZE-CONTENT', col=7, fg=(170, 170, 170))
        text(rows, 36, 'NORMAL C:/resize.txt', fg=(0, 0, 0), bg=(170, 170, 170))
    elif name == 'less':
        text(rows, 0, 'RESIZE-CONTENT')
        text(rows, 36, 'C:/resize.txt', fg=(0, 0, 0), bg=(170, 170, 170))
    else:
        # Status bar reaches the new last cell row rather than the old row 29.
        text(rows, 36, ' q quit  k kill', fg=(0, 0, 0), bg=(170, 170, 170))

# Tmux owns the physical terminal and must resize its pane, waking the pane's Vim.
script = vim.BOOT + vim.typed('Tmux;\n') + 'delay 300\n' + vim.typed('Vim("C:/resize.txt");\n')
script += 'wait NORMAL C:/resize.txt\nresize 800 600\nwait NORMAL C:/resize.txt\ndelay 400\nquit\n'
rows = run('tmux-vim', script, 800, 600, base)
text(rows, 35, 'NORMAL C:/resize.txt', fg=(0, 0, 0), bg=(170, 170, 170))
print('gpu-resize-test: three mode changes wake GetKey; Vim/Less/Top/Tmux reflow and PNG dimensions/content PASS')
