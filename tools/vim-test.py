#!/usr/bin/env python3
"""Real GetKey -> Vim -> FAT32 tests, with independent buffer/byte-cursor oracles.
All generated files live under build/vim-test. No model of the editor is used.
"""
import pathlib
import re
import subprocess
import sys
import os
import threading
import time

KEYS = {'\\': (43, False), ' ': (57, False), '\n': (28, False), '\x1b': (1, False),
        '\b': (14, False), '\t': (15, False)}
for first, lo, up in ((2, '1234567890-=', '!@#$%^&*()_+'),
                      (16, 'qwertyuiop[]', 'QWERTYUIOP{}'),
                      (30, "asdfghjkl;'", 'ASDFGHJKL:"'),
                      (44, 'zxcvbnm,./', 'ZXCVBNM<>?')):
    for i, (plain, shifted) in enumerate(zip(lo, up)):
        KEYS[plain] = (first + i, False)
        KEYS[shifted] = (first + i, True)


def keys_of(code):
    return f'1 {code} 1\n1 {code} 0\n'


def typed(text):
    result = ''
    for ch in text:
        if ch in ('\x12', '\x0f'):
            result += '1 29 1\n' + keys_of(19 if ch == '\x12' else 24) + '1 29 0\n'
        else:
            code, shift = KEYS[ch]
            if shift:
                result += '1 42 1\n'
            result += keys_of(code)
            if shift:
                result += '1 42 0\n'
        result += 'delay 3\n'
    return result


# Input-script sync (tools/coolvm/README.md): the shell has started (and run C:/Init.cool) and shows its
# prompt. Waiting for guest output instead of a fixed boot delay keeps the scripts right when
# the host is loaded (make -j test); QUIT ends the VM instead of idling until --timeout.
# A wait text must not occur in the echo of the lines typed before it: print numbers with
# %d (Print("OPEN%d", 2) echoes as OPEN%d but prints OPEN2).
BOOT = 'wait Cool shell\nwait > \n'


def wait(text):
    return f'wait {text}\n'


def finish(text, settle=200):
    """Wait for text, give the screen settle ms, then stop the VM (the screenshot is saved)."""
    return wait(text) + f'delay {settle}\nquit\n'


def check_init_log(log):
    marker = 'Running C:/Init.cool\n'
    if marker not in log:
        raise AssertionError('shell did not run C:/Init.cool')
    after_init = log.split(marker, 1)[1]
    prompt = re.search(r'(?m)^(?:[A-Z]:\S*)?> ', after_init)  # "C:/> ", or "> " without a drive
    if not prompt:
        raise AssertionError('shell did not reach a prompt after C:/Init.cool')
    diagnostics = re.findall(r'^(?:ERROR|WARNING):.*$', after_init[:prompt.start()], re.MULTILINE)
    if diagnostics:
        raise AssertionError('C:/Init.cool diagnostics:\n' + '\n'.join(diagnostics))


KERNEL_A = pathlib.Path('coolc/Frontend/KernelA.coolh').read_bytes()
BIG = ''.join(f'line {i:05d}\n' for i in range(30000))  # 330 KB, over the old 128 KiB limit

# name, starting text, actual input keys, expected text, expected byte cursor.
# Every session ends in :wq unless its test explicitly exercises quit behavior.
CASES = [
    ('kernel-a-save', KERNEL_A, 'iCHECK\x1bu\x12:w\nu', KERNEL_A, 0),
    ('gd-function', 'Target();\nU0 Target() {}\n', ':set ft=cool\ngd', 'Target();\nU0 Target() {}\n', 13),
    ('gd-class', 'Thing value;\nclass Thing {};\n', ':set ft=cool\ngd', 'Thing value;\nclass Thing {};\n', 19),
    ('gd-variable', 'value++;\n  I64 value = 1;\n', ':set ft=cool\ngd', 'value++;\n  I64 value = 1;\n', 15),
    ('gd-define', 'LIMIT\n#define LIMIT 42\n', ':set ft=cool\ngd', 'LIMIT\n#define LIMIT 42\n', 14),
    ('gd-return', 'Target();\nU0 Target() {}\n', ':set ft=cool\nlgd\x0f', 'Target();\nU0 Target() {}\n', 1),
    ('gd-warm-function', 'DoIt();\nfunction DoIt(): Unit is\n', ':set ft=warm\ngd', 'DoIt();\nfunction DoIt(): Unit is\n', 17),
    ('gd-warm-record', 'Pair\nrecord Pair is\n', ':set ft=warm\ngd', 'Pair\nrecord Pair is\n', 12),
    ('gd-warm-type', 'Size\ntype Size: Universe;\n', ':set ft=warm\ngd', 'Size\ntype Size: Universe;\n', 10),
    ('gd-ignore-comment', 'Target();\n/* U0 Target() {}\n*/\nU0 Target() {}\n', ':set ft=cool\ngd', 'Target();\n/* U0 Target() {}\n*/\nU0 Target() {}\n', 34),
    ('gd-kernel-return', 'StrCmp\n', 'gd\x0f', 'StrCmp\n', 0),
    ('gd-missing', 'UnknownName\n', 'gd\x0f', 'UnknownName\n', 0),
    ('gd-dirty-local', 'Target();\nU0 Target() {}\n', ':set ft=cool\nA \x1b0gd', 'Target(); \nU0 Target() {}\n', 14),
    ('gd-dirty-kernel', 'StrLen\n', 'A \x1b0gd', 'StrLen \n', 0),
    ('rnu-both', 'a\nb\nc\nd\n', ':set number relativenumber\njj', 'a\nb\nc\nd\n', 4),
    ('rnu-only', 'a\nb\nc\nd\n', ':set nonu rnu\njj', 'a\nb\nc\nd\n', 4),
    ('rnu-off', 'a\nb\nc\nd\n', ':set rnu\n:set nornu\njj', 'a\nb\nc\nd\n', 4),
    ('rnu-no-number', 'a\nb\nc\nd\n', ':set nonumber norelativenumber\njj', 'a\nb\nc\nd\n', 4),
    ('insert', 'abc\n', 'iX\x1b', 'Xabc\n', 0),
    ('append', 'abc\n', 'aX\x1b', 'aXbc\n', 1),
    ('first-nonblank-insert', '  abc\n', 'IX\x1b', '  Xabc\n', 2),
    ('append-end', 'abc\n', 'AX\x1b', 'abcX\n', 3),
    ('open-below', 'abc\ndef\n', 'oX\x1b', 'abc\nX\ndef\n', 4),
    ('open-above', 'abc\n', 'OX\x1b', 'X\nabc\n', 0),
    ('delete-char', 'abc\n', 'x', 'bc\n', 0),
    ('delete-count', 'abcd\n', '3x', 'd\n', 0),
    ('delete-line', 'a\nb\nc\n', 'dd', 'b\nc\n', 0),
    ('delete-three-lines', 'a\nb\nc\nd\n', '3dd', 'd\n', 0),
    ('operator-count', 'a\nb\nc\nd\n', 'd3d', 'd\n', 0),
    ('multiply-counts', 'a\nb\nc\nd\ne\n', '2d2d', 'e\n', 0),
    ('delete-word', 'one two\n', 'dw', 'two\n', 0),
    ('change-word', 'one two\n', 'cwX\x1b', 'X two\n', 0),
    ('change-line', 'one\ntwo\n', 'ccX\x1b', 'X\ntwo\n', 0),
    ('yank-line-after', 'a\nb\n', 'yyp', 'a\na\nb\n', 2),
    ('yank-line-before', 'a\nb\n', 'jyyP', 'a\nb\nb\n', 2),
    ('yank-word', 'one two\n', 'ywwP', 'one one two\n', 7),
    ('replace', 'abc\n', 'lrX', 'aXc\n', 1),
    ('replace-count', 'abcd\n', '3rX', 'XXXd\n', 2),
    ('join', 'one\n  two\n', 'J', 'one two\n', 3),
    ('join-count', 'a\nb\nc\n', '3J', 'a b c\n', 3),
    ('dot-delete', 'abcd\n', 'x.', 'cd\n', 0),
    ('dot-insert', 'abc\n', 'iX\x1bl.', 'XXabc\n', 1),
    ('dot-change', 'one two\n', 'cwX\x1bw.', 'X X\n', 2),
    ('undo', 'abc\n', 'xu', 'abc\n', 0),
    ('undo-multiple', 'abcd\n', 'xxuu', 'abcd\n', 0),
    ('redo-multiple', 'abcd\n', 'xxuu\x12\x12', 'cd\n', 0),
    ('redo-branch', 'abcd\n', 'xxuiX\x1b\x12', 'Xbcd\n', 0),
    ('insert-transaction', 'abc\n', 'iXYZ\bQ\x1bu', 'abc\n', 0),
    ('left-right', 'abcdef\n', '4l2h', 'abcdef\n', 2),
    ('five-down', 'a\nb\nc\nd\ne\nf\ng\n', '5j', 'a\nb\nc\nd\ne\nf\ng\n', 10),
    ('up', 'a\nb\nc\n', 'Gk', 'a\nb\nc\n', 2),
    ('word-forward', 'one two three\n', '2w', 'one two three\n', 8),
    ('word-back', 'one two three\n', '2wb', 'one two three\n', 4),
    ('word-end', 'one two\n', 'e', 'one two\n', 2),
    ('word-punctuation', 'one.two\n', 'w', 'one.two\n', 3),
    ('line-start', ' abc\n', '$0', ' abc\n', 0),
    ('first-nonblank', '  abc\n', '^', '  abc\n', 2),
    ('line-end', 'abc\n', '$', 'abc\n', 2),
    ('first-line', 'a\nb\nc\n', 'Ggg', 'a\nb\nc\n', 0),
    ('count-go', 'a\nb\nc\n', '2G', 'a\nb\nc\n', 2),
    ('count-gg', 'a\nb\nc\n', '3gg', 'a\nb\nc\n', 4),
    ('find', 'abcabc\n', 'fc', 'abcabc\n', 2),
    ('find-count', 'abcabc\n', '2fc', 'abcabc\n', 5),
    ('till', 'abcabc\n', 'tc', 'abcabc\n', 1),
    ('delete-find', 'abcabc\n', 'dfc', 'abc\n', 0),
    ('delete-till', 'abcabc\n', 'dtc', 'cabc\n', 0),
    ('find-missing', 'abc\n', 'fzx', 'bc\n', 0),
    ('visual-delete', 'abcd\n', 'vld', 'cd\n', 0),
    ('visual-backward', 'abcd\n', '2lvhd', 'ad\n', 1),
    ('visual-lines', 'a\nb\nc\n', 'Vjd', 'c\n', 0),
    ('visual-yank', 'abcd\n', 'vly$p', 'abcdab\n', 5),
    ('visual-change', 'abcd\n', 'vlcX\x1b', 'Xcd\n', 0),
    ('visual-cancel', 'abcd\n', 'vl\x1bx', 'acd\n', 1),
    ('search-forward', 'one two one\n', '/one\n', 'one two one\n', 8),
    ('search-next', 'a b a b a\n', '/a\nn', 'a b a b a\n', 8),
    ('search-reverse', 'a b a b a\n', '/a\nnN', 'a b a b a\n', 4),
    ('search-backward', 'a b a b a\n', '?a\n', 'a b a b a\n', 8),
    ('search-missing', 'abc\n', '/zzz\n', 'abc\n', 0),
    ('search-empty-repeat', 'a b a b a\n', '/a\n/\n', 'a b a b a\n', 8),
    ('ex-line', 'a\nb\nc\n', ':3\n', 'a\nb\nc\n', 4),
    ('ex-unknown', 'abc\n', ':bogus\n', 'abc\n', 0),
    ('empty-file', '', 'iX\x1b', 'X', 0),
    ('empty-delete', '', 'ddxu', '', 0),
    ('unterminated-last-delete', 'a\nb', 'Gdd', 'a', 0),
    ('unterminated-put', 'abc', 'yyp', 'abc\nabc\n', 4),
    ('empty-line-motion', 'a\n\nb\n', 'j', 'a\n\nb\n', 2),
    ('keep-column', 'abcdef\nx\nabcdef\n', '4ljj', 'abcdef\nx\nabcdef\n', 13),
    ('hangul-motion', '가나다abc\n', '2l', '가나다abc\n', 6),
    ('hangul-delete', '가나다\n', 'lx', '가다\n', 3),
    ('hangul-undo', '가나다\n', 'lxu', '가나다\n', 3),
    ('hangul-column', '가나다\nabcdef\n', 'lj', '가나다\nabcdef\n', 12),
    ('tab-column', '\tabc\nabcdef\n', 'lj', '\tabc\nabcdef\n', 9),
    ('vertical-scroll', 'x\n' * 60, 'G', 'x\n' * 60, 118),
    ('horizontal-scroll', 'x' * 140 + '\n', '$', 'x' * 140 + '\n', 139),
    ('write-continue', 'abc\n', 'x:w\niX\x1b', 'Xbc\n', 0),
    ('quit-dirty-refused', 'abc\n', 'x:q\niX\x1b', 'Xbc\n', 0),
    ('edit-file', 'abc\n', ':e C:/Other.txt\n', 'other\n', 0),
    ('edit-dirty-refused', 'abc\n', 'x:e C:/Other.txt\n', 'bc\n', 0),
    ('history-cap', 'x' * 40, 'x' * 35 + 'u' * 32, 'x' * 37, 0),
    ('count-cancel', 'abc\n', '3\x1bx', 'bc\n', 0),
    ('operator-cancel', 'abc\n', 'd\x1bl', 'abc\n', 1),
    ('line-delete-undo-cursor', 'abc\ndef\n', 'lddu', 'abc\ndef\n', 1),
    ('last-line-delete-cursor', '  abc\ndef', 'Gdd', '  abc', 2),
    ('word-eof', 'abc\n', 'w', 'abc\n', 2),
    ('last-char-right', 'abc\n', '$llll', 'abc\n', 2),
    ('replace-too-long', 'abc\n', '5rX', 'abc\n', 0),
    ('change-two-words', 'one two three\n', 'c2wX\x1b', 'X three\n', 0),
    ('hangul-replace', '가나다\n', 'lrX', '가X다\n', 3),
    ('hangul-yank', '가나다\n', 'vly$p', '가나다가나\n', 12),
    ('visual-line-change', 'a\nb\nc\n', 'VjcX\x1b', 'X\nc\n', 0),
    ('blank-insert-escape', 'a\nb\n', 'ji\x1b', 'a\nb\n', 2),
    ('capacity-grows', 'x' * 131071, 'iY\x1b', 'Y' + 'x' * 131071, 0),
    ('edit-large-file', 'abc\n', ':e C:/Huge.txt\nx', 'x' * 131071, 0),
    ('noop-keeps-redo', 'abcd\n', 'xxuura\x12\x12', 'cd\n', 0),
    ('replace-same-no-history', 'abc\n', 'xrbu', 'abc\n', 0),
    ('big-file-edit-undo-redo', BIG, 'GoEND\x1bggxuu\x12', BIG + 'END\n', 0),
    ('big-file-search-delete', BIG, '/line 29999\ndd', BIG.replace('line 29999\n', ''), 29998 * 11),
]


def run(args, **kw):
    return subprocess.run(args, check=True, capture_output=True, **kw)


def screen_test(d, disk, kernel):
    """Exercise framebuffer rendering with a visible wide-character selection."""
    (d / 'screen.png').unlink(missing_ok=True)
    source = d / 'Screen.cool'
    source.write_text('I64 count = 42;\n// Cool syntax and Hangul\nU8 *s = "한글";\nif (count) { Print(s); }\n')
    run(['mcopy', '-o', '-i', str(disk), str(source), '::Screen.cool'])
    script = d / 'screen-input.txt'
    script.write_text(BOOT + typed('Vim("C:/Screen.cool");\n') + wait('NORMAL C:/Screen.cool') +
                      typed('jj9lv') + wait('VISUAL C:/Screen.cool') + typed('l') + finish('\x1b[3;18H'))
    with (d / 'screen.log').open('wb') as out:
        proc = subprocess.run(['gtimeout', '-k', '2', '12', 'build/coolvm', '--headless',
                        '--cpus', '2', '--mem', '1024', '--width', '640', '--height', '480',
                        '--timeout', '7', '--screenshot', str(d / 'screen.png'),
                        '--input-script', str(script), '--disk', str(disk), kernel],
                       stdout=out, stderr=subprocess.STDOUT)
    if proc.returncode not in (0, 124):
        raise AssertionError(f'screen VM failed with {proc.returncode}')
    log = (d / 'screen.log').read_text(errors='replace')
    check_init_log(log)
    # Same ANSI stream is consumed by Fb.cool and the serial console. Check token
    # classes, selected wide glyphs, line numbers, status mode and cell cursor.
    for marker in ('\x1b[0;36mI', '\x1b[0;33m4', '\x1b[0;35mi',
                   '\x1b[0;90m/', '\x1b[0;32;44m한글',
                   '    3 ', 'VISUAL C:/Screen.cool', '\x1b[3;18H'):
        if marker not in log:
            raise AssertionError(f'missing screen marker {marker!r}; see {d / "screen.log"}')
    if not (d / 'screen.png').is_file():
        raise AssertionError('framebuffer screenshot missing')


def main():
    d = pathlib.Path('build/vim-test')
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    run(['mformat', '-i', str(disk), '-F', '-v', 'VIMTEST', '::'])

    def copy(path, name):
        run(['mcopy', '-o', '-i', str(disk), str(path), '::' + name])

    run(['tools/disk-files.sh', str(disk)])
    other = d / 'Other.txt'
    other.write_text('other\n')
    copy(other, other.name)
    huge = d / 'Huge.txt'
    huge.write_bytes(b'x' * 131072)
    copy(huge, huge.name)
    unicode_file = d / 'Unicode.txt'
    unicode_file.write_bytes(b'abc\n')
    copy(unicode_file, unicode_file.name)
    run(['mmd', '-i', str(disk), '::coolc/Frontend'])
    copy(pathlib.Path('coolc/Frontend/KernelA.coolh'), 'coolc/Frontend/KernelA.coolh')
    runner = ['U0 VimTests() {']
    script = BOOT + typed('#include "C:/Run.cool"\n') + wait('> ')
    script += typed('VimTests;\n')
    for i, (name, source, keys, expected, pos) in enumerate(CASES):
        if i:  # the previous editor has quit; the next one gets these keys
            script += wait(f'VIMRESULT {i - 1} ')
        path = d / f'T{i:03}.txt'
        path.write_bytes((source if isinstance(source, bytes) else source.encode()))
        copy(path, path.name)
        target = 'coolc/Frontend/KernelA.coolh' if name == 'kernel-a-save' else path.name
        runner.append(f'Vim("C:/{target}"); Print("\\nVIMRESULT {i} %d %d %d\\n", vim_pos, vim_top, vim_left);')
        if name == 'gd-kernel-return':
            script += typed('gd') + wait('NORMAL C:/Kernel/KUtils.cool') + typed('\x0f:wq\n') + 'delay 60\n'
        else:
            script += typed(keys + ':wq\n') + 'delay 60\n'
    # Verify ordinary and forced exits as well as a real CPU fault and a fresh invocation.
    runner += ['Vim("C:/Quit.txt"); Print("\\nQUITRESULT %d\\n", vim_pos);',
               'Vim("C:/Quit.txt"); Print("\\nCLEANQUIT\\n");', '}']
    quitfile = d / 'Quit.txt'
    quitfile.write_text('keep\n')
    copy(quitfile, quitfile.name)
    script += wait(f'VIMRESULT {len(CASES) - 1} ')
    script += typed('x:q!\n') + wait('QUITRESULT') + typed(':q\n') + wait('CLEANQUIT')
    runner += ['U0 VimUart() { Print("VIMUART\\n"); Vim("C:/Unicode.txt"); Print("UARTRESULT %d\\n", vim_pos); Print("VIMDONE\\n"); Shutdown; }']
    # Fault while the editor owns its buffers and alternate screen. The kernel
    # statement recovery must call VimClose, then another Vim session must work.
    script += typed('{VimOpen("C:/Quit.txt"); I64 *bad=0; *bad=1;}\n')
    script += typed('Print("RECOVER %d %d\\n", vim_active, shell_stmt_cleanup);\n') + wait('RECOVER 0')
    script += typed('Vim("C:/Quit.txt");\n') + wait('NORMAL C:/Quit.txt') + typed(':q\n')
    # Ctrl+Alt+C once the second editor is on the screen.
    script += typed('Print("OPEN%d\\n", 2); Vim("C:/Quit.txt");\n') + wait('OPEN2') + wait('NORMAL C:/Quit.txt')
    script += '1 29 1\n1 56 1\n' + keys_of(46) + '1 56 0\n1 29 0\n' + wait('Break')
    script += typed('Print("BREAKRECOVER %d %d\\n", vim_active, shell_stmt_cleanup);\n')
    script += typed('VimUart;\n')
    path = d / 'Run.cool'
    path.write_text('\n'.join(runner))
    copy(path, path.name)
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        proc = subprocess.Popen(['gtimeout', '-k', '2', '65', 'build/coolvm', '--headless',
                               '--cpus', '2', '--mem', '1024', '--width', '640', '--height', '480', '--timeout', '60',
                               '--input-script', str(d / 'input.txt'), '--disk', str(disk),
                               sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        def capture():
            seen = b''
            sent = False
            while True:
                data = os.read(proc.stdout.fileno(), 65536)
                if not data:
                    break
                out.write(data)
                out.flush()
                seen = (seen + data)[-131072:]
                if not sent and b'\nVIMUART\n' in seen:
                    proc.stdin.write('i한글\x1b'.encode())
                    proc.stdin.flush()
                    # Let the UART's lone-ESC timer expire before sending colon.
                    time.sleep(0.15)
                    proc.stdin.write(b':wq\r')
                    proc.stdin.flush()
                    sent = True
        reader = threading.Thread(target=capture)
        reader.start()
        proc.wait()
        reader.join()
    log = (d / 'vm.log').read_text(errors='replace')
    check_init_log(log)
    results = {int(i): (int(p), int(t), int(left)) for i, p, t, left in
               re.findall(r'VIMRESULT (\d+) (\d+) (\d+) (\d+)', log)}
    failures = []
    for i, (name, source, keys, expected, pos) in enumerate(CASES):
        filename = f'T{i:03}.txt'
        if name == 'kernel-a-save':
            filename = 'coolc/Frontend/KernelA.coolh'
        if name == 'edit-file':
            filename = 'Other.txt'
        if name == 'edit-large-file':
            filename = 'Huge.txt'
        got = run(['mcopy', '-i', str(disk), '::' + filename, '-']).stdout
        state = results.get(i)
        if got != (expected if isinstance(expected, bytes) else expected.encode()) or state is None or state[0] != pos:
            failures.append(f'{i} {name}: text={got[:150]!r} cursor={state}; expected {(expected if isinstance(expected, bytes) else expected.encode())[:150]!r}, {pos}')
        if name.startswith('rnu-'):
            end = log.index(f'VIMRESULT {i} ')
            frame = log[log.rfind('\x1b[1;1H', 0, end):end]
            numbers = {'rnu-both': [2, 1, 3, 1], 'rnu-only': [2, 1, 0, 1],
                       'rnu-off': [1, 2, 3, 4], 'rnu-no-number': None}[name]
            for row, char in enumerate('abcd', 1):
                prefix = f'\x1b[{row};1H\x1b[0m\x1b[K'
                if numbers:
                    prefix += f'\x1b[90m{numbers[row-1]:5d} '
                if prefix + '\x1b[0;37m' + char not in frame:
                    failures.append(f'{name}: wrong rendered number on row {row}')
            cursor = '\x1b[3;1H' if numbers is None else '\x1b[3;7H'
            if cursor not in frame:
                failures.append(f'{name}: wrong rendered cursor')
        if state and name == 'vertical-scroll' and state[1] == 0:
            failures.append('vertical viewport did not scroll')
        if state and name == 'horizontal-scroll' and state[2] == 0:
            failures.append('horizontal viewport did not scroll')
    if run(['mcopy', '-i', str(disk), '::Quit.txt', '-']).stdout != b'keep\n':
        failures.append(':q! unexpectedly saved changes')
    for marker in ('QUITRESULT 0', 'CLEANQUIT', 'UARTRESULT 3', 'RECOVER 0 0', 'BREAKRECOVER 0 0', 'VIMDONE'):
        if marker not in log:
            failures.append('missing ' + marker)
    if run(['mcopy', '-i', str(disk), '::Unicode.txt', '-']).stdout != '한글abc\n'.encode():
        failures.append('UART Hangul input did not preserve UTF-8')
    errors = re.findall(r'^ERROR:.*$', log, re.MULTILINE)
    if len(errors) != 1 or 'bad memory access' not in errors[0]:
        failures.append(f'unexpected guest errors: {errors}')
    if proc.returncode != 0:
        failures.append(f'VM exit status {proc.returncode}')
    if failures:
        raise SystemExit('\n'.join(failures) + f'\nFull log: {d / "vm.log"}')
    screen_test(d, disk, sys.argv[1])
    print(f'vim-test: {len(CASES) + 5} VM input/buffer/cursor, quit and fault recovery cases passed')


if __name__ == '__main__':
    main()
