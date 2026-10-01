#!/usr/bin/env python3
"""Hangul input (os/Kernel/Ime.cool) from the VM window's keyboard: 2-beolsik composition in the shell's
line editor and in Vim's insert mode, toggled by Shift+Space and by Right Alt. Input script -> UART
stream, screenshot and the file Vim saved. (The UART is not touched by the IME.)"""
import subprocess
import sys

import testvm
from testvm import ROOT


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
    testvm.create_disk(disk, 64 * 1024 * 1024, label='IMETEST')
    testvm.install_disk_files(disk)
    (d / 'H.txt').write_text('\n')
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(d / 'H.txt'), '::H.txt'], check=True)
    script = testvm.BOOT
    # Shell line editor: Print("<Hangul>\n"); typed with the IME on between the quotes.
    script += testvm.typed('Print("') + SHIFT_SPACE + testvm.typed(WORDS) + SHIFT_SPACE + testvm.typed('\\n");\n') + 'delay 600\n'
    # Vim insert mode: composed text is replaced as it grows; Backspace takes jamo off.
    script += testvm.typed('Vim("C:/H.txt");\n') + 'delay 500\n'
    script += testvm.typed('i') + RIGHT_ALT + testvm.typed('gksrmf rkqtk\b\b') + SHIFT_SPACE
    script += testvm.typed('\x1b:wq\n') + 'delay 400\n'
    script += testvm.typed('Print("\\nVIMDONE\\n");\n') + 'delay 300\n'
    # Screen: the shell line again, on a clean screen, for the screenshot.
    script += testvm.typed('Print("\\x1b[2J\\x1b[H') + SHIFT_SPACE + testvm.typed('gksrmf dkssud') + SHIFT_SPACE + testvm.typed('");\n')
    script += 'delay 600\nquit\n'
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(sys.argv[1], no_venus=True, timeout=30, input_script=d / 'input.txt', disk=disk,
        screenshot=d / 'screen.png', size=(640, 480), host_timeout=40), d / 'vm.log')
    log = (d / 'vm.log').read_text(errors='replace')
    testvm.check_init_log(log)
    failures = []
    if '\n' + EXPECT + '\n' not in log.replace('\r', ''):
        failures.append(f'the shell did not print {EXPECT!r}')
    if 'VIMDONE' not in log:
        failures.append('Vim did not finish')
    saved = subprocess.run(['mcopy', '-i', str(disk), '::H.txt', '-'], check=True, capture_output=True).stdout.decode()
    if saved != '한글 갑\n':
        failures.append(f'Vim saved {saved!r}, expected {"한글 갑" + chr(10)!r}')
    px, font = testvm.screen_of(d, 'screen.png'), testvm.load_font()
    # Row 0 is the text and the prompt (then the cursor block, which is not compared).
    bits = testvm.draw_text(font, '한글 안녕C:/> ', 14)  # the prompt follows
    if not all(px(x, y) == ((255, 255, 255) if on else (0, 0, 0)) for y, row in enumerate(bits) for x, on in enumerate(row[:80])):
        failures.append('screenshot row 0 is not 한글 안녕C:/>')
    if failures:
        raise SystemExit('\n'.join(failures) + f'\nsee {d}/vm.log and screen.png')
    print('ime-test: 2-beolsik composition (syllable moves, clusters, Backspace) in the line editor and Vim, '
          'toggled by Shift+Space and Right Alt PASS')


if __name__ == '__main__':
    main()
