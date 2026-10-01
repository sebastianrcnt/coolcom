#!/usr/bin/env python3
"""The text tools on C: (os/Disk): Find, HexDump, Diff (report and merge), Less and Man, driven
by typed shell statements; results from the UART stream, the disk files and one screenshot.

Man opens Vim at the symbol's file and line, found from the
compiler's symbol table (Vim.cool's own functions) or the kernel sources on the disk (C:/Kernel).
"""
import pathlib
import re
import subprocess
import sys

import testvm
from testvm import ROOT


A = 'alpha one\nbeta two\nalpha three\n'
B = 'alpha one\nBETA two\nnew line\nalpha three\ntail\n'
LESS = '가' * 45 + '\n' + ''.join(f'line {i:03d} of the pager test file\n' for i in range(1, 101))
PAGES = [('index', 'Man - manual index'), ('Warm', 'Warm - language overview'),
         ('WarmSyntax', 'WarmSyntax - syntax quick reference'),
         ('WarmRun', 'WarmRun / WarmCompile'), ('WarmCompile', 'WarmRun / WarmCompile'),
         ('WarmExamples', 'WarmExamples - where to find working programs'),
         ('WarmModules', 'WarmModules - OS library inputs for WarmRun'),
         ('OS.CoolOS', 'OS.CoolOS - platform modules')]
PAGES += [(name, name + ' - Warm standard library') for name in (
    'OS.Terminal', 'OS.File', 'OS.Dir', 'OS.Net', 'OS.Task', 'OS.Time', 'OS.Random',
    'OS.Error', 'OS.CoolOS.Framebuffer', 'OS.CoolOS.Key', 'OS.CoolOS.Task', 'OS.CoolOS.System')]


def line(s, wait=500):
    return testvm.typed(s + '\n') + f'delay {wait}\n'


def keys(s, wait=400):
    return testvm.typed(s) + f'delay {wait}\n'


def strip(s):
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)


def main():
    d = ROOT / 'build/text-test'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'screen.png').unlink(missing_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk, 64 * 1024 * 1024, label='TEXTTEST')
    testvm.install_disk_files(disk)
    for name, text in (('A.TXT', A), ('B.TXT', B), ('C.TXT', A), ('L.TXT', LESS)):
        p = d / name
        p.write_text(text)
        subprocess.run(['mcopy', '-o', '-i', str(disk), str(p), '::' + name], check=True)
    script = testvm.BOOT
    script += line('Print("\\nSTEP-FIND\\n"); Find("alpha", "*.TXT");')
    script += line('Find("Utf8Width", "C:/Kernel/*");', 1500)
    script += line('Print("\\nSTEP-HEX\\n"); HexDump("C:/A.TXT");')
    script += line('Print("\\nSTEP-DIFF\\n"); Diff("C:/A.TXT", "C:/B.TXT");')
    # Merge: take b's lines for both hunks.
    script += line('Print("\\nSTEP-MERGE\\n"); Diff("C:/C.TXT", "C:/B.TXT", TRUE);', 300)
    script += keys('2') + keys('2')
    script += line('Print("\\nSTEP-SAME\\n"); Diff("C:/B.TXT", "C:/B.TXT");')
    # Man: VimOpen is defined in the shell (its own file and line); the rest come from C:/Kernel.
    for i, sym in enumerate(('VimOpen', 'StrLen', 'jiffies', 'VIM_HIST', 'CTask', 'I64', 'NoSuchSymbol')):
        script += line(f'Print("\\nSTEP-MAN{i}\\n"); Man("{sym}");', 700)
        if sym not in ('I64', 'NoSuchSymbol'):
            script += keys(':q\n')
    # Default index and every generated page must be usable in the installed OS.
    for i, (page, title) in enumerate(PAGES):
        call = 'Man;' if page == 'index' else f'Man("{page}");'
        script += line(f'Print("\\nSTEP-DOC{i}\\n"); {call}', 300)
        script += testvm.wait(f'C:/Man/{page}.txt:1') + keys(':q\n')
    script += line('Print("\\nSTEP-NOPAGE\\n"); Man("OS.Missing"); Man("../Warm");')
    # Less: paging, search, and (left open for the screenshot) a wide-character line.
    script += line('Print("\\nSTEP-LESS\\n"); Less("C:/L.TXT");', 600)
    script += keys(' ') + keys('/line 090\n') + keys('g', 600) + 'quit\n'
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(sys.argv[1], no_venus=True, timeout=120, input_script=d / 'input.txt', disk=disk,
        screenshot=d / 'screen.png', size=(640, 480), host_timeout=140), d / 'vm.log')
    raw = (d / 'vm.log').read_text(errors='replace')
    testvm.check_init_log(raw)
    after = raw.split('Running C:/Init.cool', 1)[-1]
    assert 'ERROR:' not in after and 'Exception:' not in after, f'guest error; see {d}/vm.log'

    def part(a, b=None):
        i = raw.find(f'STEP-{a}\n')
        j = raw.find(f'STEP-{b}\n') if b else len(raw)
        return raw[i:j] if i >= 0 else ''

    failures = []

    def need(where, text, plain=False):
        seg = strip(where) if plain else where
        if text not in seg:
            failures.append(f'missing {text!r} in {seg[:300]!r}')

    find = strip(part('FIND', 'HEX')).replace('\r', '')
    for m in ('C:/A.TXT,1: alpha one', 'C:/A.TXT,3: alpha three', 'C:/B.TXT,1: alpha one', 'C:/B.TXT,4: alpha three',
              'C:/Kernel/Console.cool,41: I64 Utf8Width(I64 cp)', 'C:/Kernel/Key.cool,'):
        need(find, m)
    if 'beta' in find.split('Utf8Width')[0]:
        failures.append('Find printed a line without the text')
    hexd = strip(part('HEX', 'DIFF')).replace('\r', '')
    need(hexd, '00000000  61 6c 70 68 61 20 6f 6e  65 0a 62 65 74 61 20 74  |alpha one.beta t|')
    need(hexd, '00000010  77 6f 0a 61 6c 70 68 61  20 74 68 72 65 65 0a')
    need(hexd, '0000001F')
    diff = part('DIFF', 'MERGE')
    need(diff, '\x1b[31m2,2---------------------\x1b[0m')
    need(diff, 'beta two\n\x1b[36malpha one\nBETA two\nnew line\n')
    need(diff, '\x1b[31m3,5---------------------\x1b[0m')
    need(strip(part('SAME', 'MAN0')), 'Files are identical')
    merged = subprocess.run(['mcopy', '-i', str(disk), '::C.TXT', '-'], check=True, capture_output=True).stdout.decode()
    if merged != B:
        failures.append(f'merged C.TXT is {merged!r}, expected {B!r}')
    man = {i: strip(part(f'MAN{i}', f'MAN{i + 1}' if i < 6 else 'DOC0')).replace('\r', '') for i in range(7)}
    need(man[0], 'VimOpen: function, C:/Vim.cool:')
    m = re.search(r'VimOpen: function, C:/Vim.cool:(\d+)', man[0])
    if m:
        # Vim's first screen holds that line, numbered, near the top.
        need(man[0], f'{int(m.group(1)):5d} ')
        src = (ROOT / 'os/Disk/Vim.cool').read_text().split('\n')
        if not src[int(m.group(1)) - 1].startswith('Bool VimOpen('):
            failures.append(f'VimOpen line {m.group(1)} is {src[int(m.group(1)) - 1]!r}')
    def line_of(path, pattern):
        for n, l in enumerate(pathlib.Path(path).read_text().split('\n'), 1):
            if re.match(pattern, l):
                return n
        return None
    for i, (sym, kind, path, pattern) in enumerate((
            ('StrLen', 'function', 'os/Kernel/KUtils.cool', r'I64 StrLen\('),
            ('jiffies', 'global variable', 'os/Kernel/Timer.cool', r'I64 jiffies\b')), 1):
        want = line_of(ROOT / path, pattern)
        if want is None or f'{sym}: {kind}, C:/Kernel/{pathlib.Path(path).name}:{want}\n' not in man[i]:
            failures.append(f'Man({sym}): expected {kind} at {path}:{want}; got {man[i][:200]!r}')
        else:
            need(man[i], f'{want:5d} ')
    need(man[3], 'VIM_HIST: #define, C:/Vim.cool:4\n')
    need(man[4], 'CTask: type, C:/Kernel/KernelA.coolh:')
    need(man[4], 'class CTask')
    need(man[5], 'I64 is a built-in type')
    need(man[6], 'Man: unknown symbol NoSuchSymbol')
    for i, (page, title) in enumerate(PAGES):
        segment = strip(part(f'DOC{i}', f'DOC{i + 1}' if i + 1 < len(PAGES) else 'NOPAGE'))
        need(segment, f'{page}: manual, C:/Man/{page}.txt:1')
        need(segment, title)
    need(strip(part('DOC0', 'DOC1')), 'Man("Warm")')
    need(strip(part('NOPAGE', 'LESS')), 'Man: unknown symbol OS.Missing')
    need(strip(part('NOPAGE', 'LESS')), 'Man: unknown symbol ../Warm')
    less = part('LESS')
    need(strip(less), 'line 030 of the pager test file')          # page down
    need(less, '\x1b[7mline 090\x1b[0m')                         # search match in reverse video
    need(strip(less), 'line 100 of the pager test file')
    need(less, '\x1b[?1049h')
    # The Hangul line wraps at the terminal width: 40 wide characters (80 columns), then 5.
    need(less, '가' * 40 + '\x1b[2;1H\x1b[K' + '가' * 5)
    # The screenshot shows the top of L.TXT again (g): the same wrap in pixels.
    px, font = testvm.screen_of(d, 'screen.png'), testvm.load_font()
    for row, text in ((0, '가' * 40), (1, '가' * 5)):
        if not testvm.text_row_matches(px, font, row, text):
            failures.append(f'screenshot row {row} is not {text!r}')
    if failures:
        raise SystemExit('\n'.join(failures) + f'\nsee {d}/vm.log and screen.png')
    print('text-test: Find, HexDump, Diff (report, merge), Man (symbols, Warm pages and index) and Less '
          '(paging, search, UTF-8 wrap, screenshot) PASS')


if __name__ == '__main__':
    main()
