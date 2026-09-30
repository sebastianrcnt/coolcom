#!/usr/bin/env python3
"""Hangul input (os/Kernel/Ime.cool) from the VM window's keyboard: 2-beolsik composition in the shell's
line editor and in Vim's insert mode, toggled by Shift+Space and by Right Alt. Input script -> UART
stream, screenshot and the file Vim saved. (The UART is not touched by the IME.)"""
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

SHIFT_SPACE = '1 42 1\n1 57 1\n1 57 0\n1 42 0\ndelay 30\n'
RIGHT_ALT = '1 100 1\n1 100 0\ndelay 30\n'
# Words: 한글 안녕 갑사 (a final that moves to the next syllable) 과 (ㅗ+ㅏ) 값 (a two-consonant final)
# and gksrm<Backspace>k = 한 + ㄱ(taken back to the lone consonant) + ㅏ = 가.
WORDS = 'gksrmf dkssud rkqtk rhk rkqt gksrm\bk'
EXPECT = '한글 안녕 갑사 과 값 한가'


def main():
    d = ROOT / 'build/ime-test'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'screen.png').unlink(missing_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'IMETEST', '::'], check=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True)
    (d / 'H.txt').write_text('\n')
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(d / 'H.txt'), '::H.txt'], check=True)
    script = vim.BOOT
    # Shell line editor: Print("<Hangul>\n"); typed with the IME on between the quotes.
    script += vim.typed('Print("') + SHIFT_SPACE + vim.typed(WORDS) + SHIFT_SPACE + vim.typed('\\n");\n') + 'delay 600\n'
    # Vim insert mode: composed text is replaced as it grows; Backspace takes jamo off.
    script += vim.typed('Vim("C:/H.txt");\n') + 'delay 500\n'
    script += vim.typed('i') + RIGHT_ALT + vim.typed('gksrmf rkqtk\b\b') + SHIFT_SPACE
    script += vim.typed('\x1b:wq\n') + 'delay 400\n'
    script += vim.typed('Print("\\nVIMDONE\\n");\n') + 'delay 300\n'
    # Screen: the shell line again, on a clean screen, for the screenshot.
    script += vim.typed('Print("\\x1b[2J\\x1b[H') + SHIFT_SPACE + vim.typed('gksrmf dkssud') + SHIFT_SPACE + vim.typed('");\n')
    script += 'delay 600\nquit\n'
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(['gtimeout', '-k', '2', '40', 'build/coolvm', '--headless', '--no-logos', '--cpus', '2', '--mem', '1024',
                        '--timeout', '30', '--width', '640', '--height', '480', '--input-script', str(d / 'input.txt'),
                        '--disk', str(disk), '--screenshot', str(d / 'screen.png'), sys.argv[1]],
                       stdout=out, stderr=subprocess.STDOUT)
    log = (d / 'vm.log').read_text(errors='replace')
    vim.check_init_log(log)
    failures = []
    if '\n' + EXPECT + '\n' not in log.replace('\r', ''):
        failures.append(f'the shell did not print {EXPECT!r}')
    if 'VIMDONE' not in log:
        failures.append('Vim did not finish')
    saved = subprocess.run(['mcopy', '-i', str(disk), '::H.txt', '-'], check=True, capture_output=True).stdout.decode()
    if saved != '한글 갑\n':
        failures.append(f'Vim saved {saved!r}, expected {"한글 갑" + chr(10)!r}')
    px, font = verify.screen_of(d, 'screen.png'), verify.load_font()
    # Row 0 is the text and the prompt (then the cursor block, which is not compared).
    bits = verify.draw_text(font, '한글 안녕C:/> ', 14)  # the prompt follows
    if not all(px(x, y) == ((255, 255, 255) if on else (0, 0, 0)) for y, row in enumerate(bits) for x, on in enumerate(row[:80])):
        failures.append('screenshot row 0 is not 한글 안녕C:/>')
    if failures:
        raise SystemExit('\n'.join(failures) + f'\nsee {d}/vm.log and screen.png')
    print('ime-test: 2-beolsik composition (syllable moves, clusters, Backspace) in the line editor and Vim, '
          'toggled by Shift+Space and Right Alt PASS')


if __name__ == '__main__':
    main()
