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

def text(s):
    return vim.typed(s)[:-len(vim.keys_of(28))]

def prefix(ch):
    return '1 29 1\n' + vim.keys_of(48) + '1 29 0\n' + text(ch)

def main():
    d = ROOT / 'build/tmux-test'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'screen.png').unlink(missing_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(40 * 1024 * 1024)
    subprocess.run(['newfs_msdos', '-F', '32', '-S', '512', '-c', '1', '-s', '81920',
                    '-h', '16', '-u', '63', '-v', 'TMUXTEST', str(disk)], check=True, capture_output=True)
    for p in (ROOT / 'os/Disk').glob('*.HC'):
        subprocess.run(['mcopy', '-o', '-i', str(disk), str(p), '::' + p.name], check=True)
    # Same symbol name in both compilers must retain different values. Left
    # sleeps while the right shell compiles and executes, then both are visible.
    script = 'delay 4500\n' + vim.typed('Tmux;') + 'delay 1500\n'
    script += vim.typed('I64 Value=111;') + prefix('%') + 'delay 1500\n'
    script += vim.typed('I64 Value=222;') + prefix('"') + 'delay 1200\n'
    script += vim.typed('I64 Value=333;') + vim.typed('while (TRUE) {}') + 'delay 300\n'
    script += prefix('x') + 'delay 300\n' + prefix('c') + 'delay 1200\n'
    script += vim.typed('I64 Value=444;') + prefix('n') + 'delay 200\n'
    script += vim.typed('Value++;') + prefix('p') + 'delay 200\n'
    script += vim.typed('Value++;') + prefix('x') + 'delay 200\n'
    # Directional focus selects the left pane; o returns to the right later.
    script += '1 29 1\n' + vim.keys_of(48) + '1 29 0\n' + vim.keys_of(105) + 'delay 300\n' 
    script += vim.typed('Sleep(1500); Print("\\x1b[2J\\x1b[HLEFT-%d\\n",Value);')
    script += prefix('o') + vim.typed('Print("\\x1b[2J\\x1b[HRIGHT-%d\\n",Value);')
    script += 'delay 2000\n' + prefix('d') + 'delay 300\n' + vim.typed('Tmux;')
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(['gtimeout', '-k', '2', '35', 'build/coolvm', '--headless', '--cpus', '2',
                        '--mem', '1024', '--timeout', '23', '--width', '640', '--height', '480',
                        '--input-script', str(d / 'input.txt'), '--disk', str(disk),
                        '--screenshot', str(d / 'screen.png'), sys.argv[1]], stdout=out, stderr=subprocess.STDOUT)
    log = (d / 'vm.log').read_text(errors='replace')
    vim.check_init_log(log)
    after_boot = log.split('SELFTEST PASS', 1)[-1]
    assert 'heap overflow' not in after_boot, 'heap corruption during shell compilation'
    assert 'ERROR:' not in after_boot and 'Exception:' not in after_boot, 'unexpected shell/kernel exception'
    px, font = verify.screen_of(d, 'screen.png'), verify.load_font()
    for label, col in [('LEFT-111', 0), ('RIGHT-223', 40)]:
        bits = verify.draw_text(font, label, len(label))
        assert any(all(px(col * 8 + x, y0 * 16 + y) == ((255, 255, 255) if on else (0, 0, 0))
                       for y, row in enumerate(bits) for x, on in enumerate(row))
                   for y0 in range(28)), f'{label} absent from its pane; see {d}/vm.log and screen.png'
    print('Tmux: independent JIT definitions, busy-loop close, concurrent Sleep, both splits, window/focus navigation, detach/reattach and both framebuffer results PASS')

if __name__ == '__main__':
    main()
