#!/usr/bin/env python3
"""Ansi.cool and the consoles' colors: typed shell statements -> framebuffer pixels.

Twice: on the framebuffer console directly, and inside a Tmux pane (Term.cool cells
re-emitted to the framebuffer). The statements print with 256-color and truecolor SGR
(38;5 48;5 38;2 48;2), save and restore the cursor, and print AnsiTermSize, which must
be the task's terminal size: 30x80 for the 640x480 screen, 29x80 in a pane (the status row).
"""
import importlib.util
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


vim = module('vim_test', ROOT / 'tools/vim-test.py')
verify = module('kernel_verify', ROOT / 'tools/kernel-verify.py')
vim.KEYS[' '] = (57, False)

STATEMENTS = [
    'AnsiClear; AnsiHome; AnsiFg(196); Print("A"); AnsiFg(AnsiRgb(255,128,0)); Print("B"); '
    'AnsiBg(21); AnsiFg(231); Print("C"); AnsiReset; '
    'Print("\\x1b[48;2;1;2;3m\\x1b[38;5;46mD\\x1b[0m");',
    'AnsiCursor(10,5); Print("S"); AnsiCursorSave; AnsiCursor(12,1); Print("T"); '
    'AnsiCursorRestore; Print("R");',
    'I64 r, c; AnsiTermSize(&r,&c); AnsiCursor(14,1); Print("SIZE %d %d\\n", r, c);',
]


def line(s):
    return vim.typed(s + '\n') + 'delay 400\n'


def cell_colors(px, col, row):
    return {px(col * 8 + x, row * 16 + y) for y in range(16) for x in range(8)}


def check(d, size):
    px, font = verify.screen_of(d, 'screen.png'), verify.load_font()
    black = (0, 0, 0)
    for col, fg, bg in ((0, (255, 0, 0), black), (1, (255, 128, 0), black),
                        (2, (255, 255, 255), (0, 0, 255)), (3, (0, 255, 0), (1, 2, 3))):
        got = cell_colors(px, col, 0)
        assert got == {fg, bg}, f'cell {col}: {sorted(got)}, expected {fg} on {bg}'
    assert px(0, 0) == black, 'A cell background is not black'
    # S, then R right after it (the cursor was saved after S), T on its own row.
    for label, col, row in (('S', 4, 9), ('R', 5, 9), ('T', 0, 11)):
        bits = verify.draw_text(font, label, 1)
        assert all(px(col * 8 + x, row * 16 + y) == ((255, 255, 255) if on else black)
                   for y, r in enumerate(bits) for x, on in enumerate(r)), f'{label} not at row {row} col {col}'
    text = f'SIZE {size} 80'
    assert verify.text_row_matches(px, font, 13, text), f'{text!r} is not on row 13'


def scenario(name, tmux, size):
    d = ROOT / 'build/ansi-test' / name
    d.mkdir(parents=True, exist_ok=True)
    (d / 'screen.png').unlink(missing_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'ANSITEST', '::'], check=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True)
    script = vim.BOOT
    if tmux:
        script += line('Tmux;') + 'delay 1500\n'
    for s in STATEMENTS:
        script += line(s)
    script += vim.finish(f'SIZE {size} 80', 300)  # the last statement's output
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(['gtimeout', '-k', '2', '30', 'build/coolvm', '--headless', '--no-venus', '--cpus', '2', '--mem', '1024',
                        '--timeout', '16', '--width', '640', '--height', '480', '--input-script', str(d / 'input.txt'),
                        '--disk', str(disk), '--screenshot', str(d / 'screen.png'), sys.argv[1]],
                       stdout=out, stderr=subprocess.STDOUT)
    log = (d / 'vm.log').read_text(errors='replace')
    vim.check_init_log(log)
    after = log.split('Running C:/Init.cool', 1)[-1]
    assert 'ERROR:' not in after and 'Exception:' not in after, f'guest error; see {d}/vm.log'
    try:
        check(d, size)
    except AssertionError as e:
        raise SystemExit(f'ansi-test {name}: {e}; see {d}/vm.log and screen.png')


if __name__ == '__main__':
    scenario('console', False, 30)
    scenario('tmux', True, 29)
    print('ansi-test: 256-color and truecolor SGR, cursor save/restore and AnsiTermSize on the console and in a Tmux pane PASS')
