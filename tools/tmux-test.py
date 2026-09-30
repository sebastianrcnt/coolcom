#!/usr/bin/env python3
"""Real keyboard -> Tmux -> independent JIT shells -> framebuffer pixels."""
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
vim.KEYS[chr(92)] = (43, False)
vim.KEYS['|'] = (43, True)

def text(s):
    return vim.typed(s)

def line(s):
    return vim.typed(s + "\n")

def prefix(ch):
    return '1 29 1\n' + vim.keys_of(48) + '1 29 0\n' + text(ch)

# Tmux repaints at most 30 times a second, by changed cells: text typed into a pane (its echo)
# is not contiguous in the output, and text a statement prints is only seen if it stays on the
# screen until the next repaint. A wait in a pane matches text printed in one piece that stays.

def check_pixels(d, labels):
    px, font = verify.screen_of(d, 'screen.png'), verify.load_font()
    for label, col in labels:
        bits = verify.draw_text(font, label, len(label))
        assert any(all(px(col * 8 + x, y0 * 16 + y) == ((255, 255, 255) if on else (0, 0, 0))
                       for y, row in enumerate(bits) for x, on in enumerate(row))
                   for y0 in range(28)), f'{label} absent from its pane; see {d}/vm.log and screen.png'


def vim_panes(kernel):
    """Two editors coexist; cleanup from one shell must never close the other."""
    d = ROOT / 'build/tmux-vim-test'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'screen.png').unlink(missing_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'TMUXVIM', '::'], check=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True)
    for name, contents in [('Left.txt', b'abc\n'), ('Right.txt', b'xyz\n'), ('Page.txt', b'x\n' * 60)]:
        p = d / name
        p.write_bytes(contents)
        subprocess.run(['mcopy', '-o', '-i', str(disk), str(p), '::' + name], check=True)
    script = vim.BOOT + 'delay 2500\n' + line('Tmux;') + 'delay 1500\n' + prefix('%') + 'delay 1500\n'
    script += line('Vim("C:/Right.txt");') + 'delay 300\n' + text('iRIGHT\x1b')
    script += prefix('o') + line('Vim("C:/Left.txt");') + 'delay 300\n' + text('iLEFT\x1b')
    # Finishing the right statement and executing another must leave left Vim alive.
    script += prefix('o') + text(':wq\n') + 'delay 200\n'
    script += line('I64 Other=17;') + line('Vim("C:/Right.txt");') + 'delay 300\n'
    script += prefix('o') + text('A!\x1b:wq\n') + 'delay 200\n'
    # Break and fault the left editor while right Vim still owns its cleanup hook.
    script += line('I64 BreakReturned=0,FaultReturned=0;')
    script += line('U0 BreakEditor(){Vim("C:/Left.txt"); BreakReturned=1;}')
    script += line('U0 FaultEditor(){VimOpen("C:/Left.txt"); I64 *bad=0; *bad=1; FaultReturned=1;}')
    script += 'delay 500\n' + line('Print("BRK%d\\n", 1); Sleep(200); BreakEditor;') + vim.wait('BRK1') + 'delay 1000\n'
    script += '1 29 1\n1 56 1\n' + vim.keys_of(46) + '1 56 0\n1 29 0\n' + 'delay 300\n'
    script += line('I64 Broken=vim_active || shell_stmt_cleanup || BreakReturned;')
    script += line('FaultEditor;') + 'delay 300\n'
    script += line('Broken+=vim_active || shell_stmt_cleanup || FaultReturned;')
    script += line('Print("\\x1b[2J\\x1b[HLEFT-CLEAN-%d\\n",Broken);')
    script += prefix('o') + text('A!\x1b:wq\n') + 'delay 200\n'
    script += line('I64 bad = ;')  # a compile error in a pane prints ERROR
    script += line('Vim("C:/Page.txt");') + 'delay 300\n'
    script += vim.keys_of(109) + 'delay 100\n'  # PageDown: 28 text rows in a 29-row pane
    script += '1 29 1\n' + vim.keys_of(22) + '1 29 0\n'  # Ctrl+U: back 14 rows
    script += text('iPAGE\x1b:wq\n') + 'delay 200\n'
    script += line('Print("\\x1b[2J\\x1b[HRIGHT-CLEAN-%d\\n",vim_active || shell_stmt_cleanup);')
    script += vim.finish('RIGHT-CLEAN-0', 300)
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        proc = subprocess.run(['gtimeout', '-k', '2', '30', 'build/coolvm', '--headless', '--no-logos', '--cpus', '2',
                               '--mem', '1024', '--timeout', '25', '--width', '640', '--height', '480',
                               '--input-script', str(d / 'input.txt'), '--disk', str(disk),
                               '--screenshot', str(d / 'screen.png'), kernel], stdout=out, stderr=subprocess.STDOUT)
    assert proc.returncode in (0, 124), f'Vim pane VM exited {proc.returncode}; see {d}/vm.log'
    log = (d / 'vm.log').read_text(errors='replace')
    vim.check_init_log(log)
    after_boot = log.split('SELFTEST PASS', 1)[-1]
    assert 'heap overflow' not in after_boot and '*** Exception:' not in after_boot, 'kernel failure in Vim panes'
    assert 'ERROR: Expected an expression' in after_boot, 'no compile error in the pane'
    # Recovery restores the primary screen before a compositor tick can copy
    # alternate-screen diagnostics. Broken instead checks that both statements
    # aborted before their post-Vim/post-fault assignments and cleared cleanup.
    for name, expected in [('Left.txt', b'LEFTabc!\n'), ('Right.txt', b'RIGHTxyz!\n'),
                           ('Page.txt', b'x\n' * 14 + b'PAGEx\n' + b'x\n' * 45)]:
        got = subprocess.run(['mcopy', '-i', str(disk), '::' + name, '-'], check=True, capture_output=True).stdout
        assert got == expected, f'{name}: {got!r}, expected {expected!r}; see {d}/vm.log'
    check_pixels(d, [('LEFT-CLEAN-0', 0), ('RIGHT-CLEAN-0', 40)])
    print('Tmux Vim: concurrent editors, per-pane save/page scrolling, normal/break/fault cleanup isolation and shell restoration PASS')


def exit_panes(kernel):
    """exit/Exit() closes panes and windows; the last pane restores the original shell."""
    d = ROOT / 'build/tmux-exit-test'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'screen.png').unlink(missing_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(40 * 1024 * 1024)
    subprocess.run(['newfs_msdos', '-F', '32', '-S', '512', '-c', '1', '-s', '81920',
                    '-h', '16', '-u', '63', '-v', 'TMUXEXIT', str(disk)], check=True, capture_output=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True)
    # Closing the last pane returns to the invoking compiler, preserving its definitions.
    script = vim.BOOT + line('I64 Keep=41;') + line('Tmux;') + 'delay 2500\n'
    script += line('exit') + 'delay 500\n'
    script += line('Print("BACK%d-%d\\n", Keep, tm_session==NULL);') + vim.wait('BACK41-1')
    # Exit() in the right pane expands the left pane back to the full terminal width.
    script += line('Tmux;') + 'delay 2500\n' + prefix('%') + 'delay 2500\n'
    script += line('Exit();') + 'delay 500\n'
    script += line('Print("LEFT%d-%d\\n", 2, VtCurrent->cols);') + vim.wait('LEFT2-80')
    # Closing the selected window focuses the surviving window.
    script += prefix('c') + 'delay 2500\n' + line('exit') + 'delay 500\n'
    script += line('Print("WIN%d\\n", 3);') + vim.wait('WIN3')
    # A background window and then an inactive pane can end while another has focus.
    script += prefix('c') + 'delay 2500\n'
    script += line('Sleep(1000); Exit();') + prefix('n') + 'delay 1500\n'
    script += line('Print("HIDDEN%d\\n", 4);') + vim.wait('HIDDEN4')
    script += prefix('%') + 'delay 2500\n'
    script += line('Sleep(1000); Exit();') + prefix('o') + 'delay 1500\n'
    script += line('Print("INACTIVE%d-%d\\n", 5, VtCurrent->cols);') + vim.wait('INACTIVE5-80')
    script += line('Exit();') + 'delay 500\n'
    script += line('Print("\\x1b[2J\\x1b[HBACK%d-%d\\n", Keep+1, tm_session==NULL);')
    script += vim.finish('BACK42-1', 300)
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        proc = subprocess.run(['gtimeout', '-k', '2', '50', 'build/coolvm', '--headless', '--no-logos', '--cpus', '2',
                               '--mem', '1024', '--timeout', '45', '--width', '640', '--height', '480',
                               '--input-script', str(d / 'input.txt'), '--disk', str(disk),
                               '--screenshot', str(d / 'screen.png'), kernel], stdout=out, stderr=subprocess.STDOUT)
    log = (d / 'vm.log').read_text(errors='replace')
    vim.check_init_log(log)
    after_boot = log.split('SELFTEST PASS', 1)[-1]
    assert 'heap overflow' not in after_boot and '*** Exception:' not in after_boot, 'kernel failure'
    assert 'ERROR:' not in after_boot, 'unexpected shell exception'
    assert proc.returncode == 0, f'exit VM failed; see {d}/vm.log'
    for marker in ['BACK41-1', 'LEFT2-80', 'WIN3', 'HIDDEN4', 'INACTIVE5-80', 'BACK42-1']:
        assert marker in after_boot, f'{marker} missing; see {d}/vm.log'
    check_pixels(d, [('BACK42-1', 0)])
    print('Tmux exit: last pane returns to original compiler, active/inactive panes expand, active/background windows close PASS')


def main():
    d = ROOT / 'build/tmux-test'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'screen.png').unlink(missing_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(40 * 1024 * 1024)
    subprocess.run(['newfs_msdos', '-F', '32', '-S', '512', '-c', '1', '-s', '81920',
                    '-h', '16', '-u', '63', '-v', 'TMUXTEST', str(disk)], check=True, capture_output=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True)
    # Same symbol name in both compilers must retain different values. Left
    # sleeps while the right shell compiles and executes, then both are visible.
    script = vim.BOOT + line('Tmux;') + 'delay 1500\n'
    script += line('I64 Value=111;') + prefix('%') + 'delay 1500\n'
    script += line('I64 Value=222;') + prefix('"') + 'delay 1200\n'
    script += line('I64 Value=333;') + line('while (TRUE) {}') + 'delay 300\n'
    script += prefix('x') + 'delay 300\n' + prefix('c') + 'delay 1200\n'
    script += line('I64 Value=444;') + prefix('n') + 'delay 200\n'
    script += line('Value++;') + prefix('p') + 'delay 200\n'
    script += line('Value++;') + prefix('x') + 'delay 200\n'
    # Directional focus selects the left pane; o returns to the right later.
    script += '1 29 1\n' + vim.keys_of(48) + '1 29 0\n' + vim.keys_of(105) + 'delay 300\n'
    script += line('Sleep(1500); Print("\\x1b[2J\\x1b[HLEFT-%d\\n",Value);')
    script += prefix('o') + line('Print("\\x1b[2J\\x1b[HRIGHT-%d\\n",Value);')
    script += vim.wait('LEFT-111') + prefix('d') + 'delay 300\n' + line('Tmux;')
    # The redraw after reattaching: row 0 holds LEFT-111, then RIGHT-223.
    script += vim.wait('Tmux;') + vim.wait('LEFT-111') + vim.finish('RIGHT-223', 300)
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(['gtimeout', '-k', '2', '35', 'build/coolvm', '--headless', '--no-logos', '--cpus', '2',
                        '--mem', '1024', '--timeout', '23', '--width', '640', '--height', '480',
                        '--input-script', str(d / 'input.txt'), '--disk', str(disk),
                        '--screenshot', str(d / 'screen.png'), sys.argv[1]], stdout=out, stderr=subprocess.STDOUT)
    log = (d / 'vm.log').read_text(errors='replace')
    vim.check_init_log(log)
    after_boot = log.split('SELFTEST PASS', 1)[-1]
    assert 'heap overflow' not in after_boot, 'heap corruption during shell compilation'
    assert 'ERROR:' not in after_boot and 'Exception:' not in after_boot, 'unexpected shell/kernel exception'
    check_pixels(d, [('LEFT-111', 0), ('RIGHT-223', 40)])
    print('Tmux: independent JIT definitions, busy-loop close, concurrent Sleep, both splits, window/focus navigation, detach/reattach and both framebuffer results PASS')

if __name__ == '__main__':
    main()
    vim_panes(sys.argv[1])
    exit_panes(sys.argv[1])
