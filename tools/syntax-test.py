#!/usr/bin/env python3
"""Vim syntax highlighting (os/Kernel/Syntax.cool, coolc/Fmt/HCTok.cool): typed shell statements
-> Vim's ANSI stream on the UART log, plus one framebuffer pixel check.

Cool text: comments (with the block comment's state kept across lines and scrolling), preprocessor,
strings, numbers, keywords, types, labels, and identifiers colored by the shell compiler's
symbol table (a kernel function, a kernel global, a call not compiled yet). Warm text: comments,
multi-line docstrings, keywords, types, constants. Plain text: no colors until :set ft=cool.
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

COOL = '''/* block comment
   spans lines */
#include "C:/Nyan.cool"
I64 Sample(CTask *t, U8 *s)
{
    I64 x = 0x1F + StrLen(s);
    if (jiffies) return Later(x); // note
    lbl: x++;
    fp = &MemCpy; fp = &VimOpen; fp = &Missing;
    return x;
}
'''
WARM = '''-- a warm comment
module body Demo is
    """doc
    string"""
    function main(x: Int): Bool is
        return true;
    end;
end module body.
'''
TEXT = 'return 42 // not code\n'
BIG = '/*\n' + 'comment line\n' * 60 + '*/\nI64 after;\n'

# (file, keys typed in Vim, markers that must appear in the UART stream)
CASES = [
    ('Syn.cool', '', [
        '\x1b[0;90m/* block comment', '\x1b[0;90m   spans lines */',
        '\x1b[0;35m#include', '\x1b[0;32m"C:/Nyan.cool"',
        '\x1b[0;36mI64', '\x1b[0;94mSample', '\x1b[0;36mCTask',
        '\x1b[0;33m0x1F', '\x1b[0;94mStrLen', '\x1b[0;96mjiffies',
        '\x1b[0;35mif', '\x1b[0;35mreturn', '\x1b[0;94mLater', '\x1b[0;90m// note',
        '\x1b[0;33mlbl:', '\x1b[0;94mMemCpy', '\x1b[0;94mVimOpen']),
    ('Syn.warm', '', [
        '\x1b[0;90m-- a warm comment', '\x1b[0;35mmodule', '\x1b[0;32m"""doc',
        '\x1b[0;32m    string"""', '\x1b[0;94mmain', '\x1b[0;36mInt', '\x1b[0;36mBool',
        '\x1b[0;33mtrue']),
    ('Syn.txt', '', ['\x1b[0;37mreturn 42 // not code']),
    ('Syn.txt', ':set ft=cool\n', ['\x1b[0;35mreturn', '\x1b[0;90m// not code']),
    # The block comment's opening line is far above the screen: still a comment.
    ('Big.cool', 'G', ['   40 \x1b[0;90mcomment line', '\x1b[0;36mI64']),
    # The legacy extensions (.HC .aum) are still highlighted.
    ('Old.HC', '', ['\x1b[0;90m/* block comment', '\x1b[0;35m#include', '\x1b[0;36mI64', '\x1b[0;94mStrLen']),
    ('Old.aum', '', ['\x1b[0;90m-- a warm comment', '\x1b[0;35mmodule', '\x1b[0;36mInt']),
]


def line(s):
    return vim.typed(s + '\n') + 'delay 300\n'


def main():
    d = ROOT / 'build/syntax-test'
    d.mkdir(parents=True, exist_ok=True)
    (d / 'screen.png').unlink(missing_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'SYNTEST', '::'], check=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True)
    for name, text in (('Syn.cool', COOL), ('Syn.warm', WARM), ('Syn.txt', TEXT), ('Big.cool', BIG),
                       ('Old.HC', COOL), ('Old.aum', WARM)):
        p = d / name
        p.write_text(text)
        subprocess.run(['mcopy', '-o', '-i', str(disk), str(p), '::' + name], check=True)
    script = vim.BOOT
    for i, (name, keys, _) in enumerate(CASES):
        # CASE%d: the wait matches the output, not the echo of the line.
        script += line(f'Print("\\nCASE%d\\n", {i}); Vim("C:/{name}");')
        script += vim.wait(f'CASE{i}') + vim.wait(f'NORMAL C:/{name}')
        if keys:
            script += vim.typed(keys) + 'delay 300\n'
        script += vim.typed(':q!\n') + 'delay 300\n'
    # Leave the Warm file open for the screenshot.
    script += line('Print("\\nSHOT%d\\n", 1); Vim("C:/Syn.warm");')
    script += vim.wait('SHOT1') + vim.finish('NORMAL C:/Syn.warm', 500)
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(['gtimeout', '-k', '2', '60', 'build/coolvm', '--headless', '--cpus', '2', '--mem', '1024',
                        '--timeout', '45', '--width', '640', '--height', '480', '--input-script', str(d / 'input.txt'),
                        '--disk', str(disk), '--screenshot', str(d / 'screen.png'), sys.argv[1]],
                       stdout=out, stderr=subprocess.STDOUT)
    log = (d / 'vm.log').read_text(errors='replace')
    vim.check_init_log(log)
    after = log.split('Running C:/Init.cool', 1)[-1]
    assert 'ERROR:' not in after and 'Exception:' not in after, f'guest error; see {d}/vm.log'
    failures = []
    for i, (name, keys, markers) in enumerate(CASES):
        a = log.find(f'CASE{i}\n')
        b = log.find(f'CASE{i + 1}\n') if i + 1 < len(CASES) else len(log)
        part = log[a:b] if a >= 0 else ''
        for m in markers:
            if m not in part:
                failures.append(f'case {i} ({name} {keys!r}): missing {m!r}')
    if 'Syn.txt' in log and '\x1b[0;35mreturn 42' in log.split('CASE3', 1)[0]:
        failures.append('plain text was colored')
    px = verify.screen_of(d, 'screen.png')
    # "true" of `return true;` on Vim row 5: text starts at column 6 + 8 indent + "return ".
    colors = {px(21 * 8 + x, 5 * 16 + y) for y in range(16) for x in range(8)}
    if colors != {(0, 0, 0), (0xAA, 0x55, 0)}:
        failures.append(f'Warm constant cell colors {sorted(colors)}')
    if failures:
        raise SystemExit('\n'.join(failures) + f'\nsee {d}/vm.log and screen.png')
    print('syntax-test: Cool/Warm/plain highlighting by extension, block-comment state across scrolling, '
          'compiler symbol-table colors and framebuffer pixels PASS')


if __name__ == '__main__':
    main()
