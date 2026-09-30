#!/usr/bin/env python3
"""Unix-style command lines and Tab completion in the shell (os/Kernel/ShellCmd.cool), typed on the VM
window's keyboard: `vim a.cool` runs Vim("a.cool"); with the arguments typed by the function's own
parameter types, HolyC lines are unaffected, and Tab completes symbols (first word ignoring case),
file names after a command and inside strings, and lists candidates when nothing more is shared."""
import importlib.util
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(obj)
    return obj


vim = module('vim_test', ROOT / 'tools/vim-test.py')
vim.KEYS[' '] = (57, False)
vim.KEYS['|'] = (43, True)


def line(s, wait=350):
    return vim.typed(s + '\n') + f'delay {wait}\n'


def keys(s, wait=300):
    return vim.typed(s) + f'delay {wait}\n'


def strip(s):
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)


def main():
    d = ROOT / 'build/cmdline-test'
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'CMDTEST', '::'], check=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True)
    (d / 'A.TXT').write_text('alpha one\nbeta two\n')
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(d / 'A.TXT'), '::A.TXT'], check=True)
    script = vim.BOOT
    script += line('U0 Zzquux(U8 *s, I64 n) {Print("ZZ[%s][%d]\\n", s, n);}')
    script += line('U0 Zzquuz(U8 *s) {Print("QQ[%s]\\n", s);}')
    script += line('U0 Pingpong() {Print("PONG\\n");}')
    script += line('Print("\\nSTEP-CMD\\n");')
    script += line('zzquux hello 42')
    script += line('zzquux "two words" 0x10')
    script += line("zzquux 'a b' -5")
    script += line('zzquuz -x;')
    script += line('find alpha *.TXT')
    script += line('pingpong')
    script += line('ls')
    script += line('Print("plain\\n"); I64 zq = 5; zq++; Print("%d\\n", zq);')
    script += line('Zzquux("x", 1);')
    script += line('Print("\\nSTEP-TAB\\n");')
    script += keys('zzq\t') + keys('\t') + line('x two 7')                    # -> Zzquu, the list, Zzquux
    script += keys('hexdump C:/Ker\t') + keys('Ime.c\t') + line('0 4')         # files after a command
    script += keys('Print("C:/Ker\t') + line('\\n");')                         # a file name inside a string
    script += keys('hexdump C:/Kernel/Dsk\t') + keys('Blk.cool 0 2\n', 500)    # a list, then finished by hand
    script += keys('Prin\t') + keys('\t') + line('("\\nSTEP-P\\n");')            # Print, PrintErr, ... listed
    script += line('Print("\\nSTEP-END\\n");')
    script += vim.wait('STEP-END') + vim.finish('STEP-END')  # the echo, then the output
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(['gtimeout', '-k', '2', '60', 'build/coolvm', '--headless', '--cpus', '2', '--mem', '1024',
                        '--timeout', '40', '--width', '640', '--height', '480', '--input-script', str(d / 'input.txt'),
                        '--disk', str(disk), sys.argv[1]], stdout=out, stderr=subprocess.STDOUT)
    raw = (d / 'vm.log').read_text(errors='replace')
    if 'Running C:/Init.cool' not in raw:
        raise SystemExit('shell did not run C:/Init.cool')
    text = strip(raw).replace('\r', '')
    failures = []
    outputs = text.split('STEP-CMD\n', 1)[-1]
    # Output lines only (a typed line is echoed after the prompt, "C:/> ").
    out_lines = [l for l in outputs.split('\n') if not re.match(r'([A-Z]:\S*)?> ', l)]
    for want in ('ZZ[hello][42]', 'ZZ[two words][16]', 'ZZ[a b][-5]', 'QQ[-x]', 'C:/A.TXT,1: alpha one', 'PONG',
                 'Directory of C:/', 'plain', '6', 'ZZ[x][1]', 'ZZ[two][7]', '00000000  2f 2f 20 48',
                 'C:/Kernel/', 'DskBlk.cool', 'DskCache.cool', 'Print  '):
        if not any(want in l for l in out_lines):
            failures.append(f'missing output {want!r}')
    if not any(l.startswith('Zzquux') and 'Zzquuz' in l for l in out_lines):
        failures.append('the second Tab did not list Zzquux and Zzquuz')
    if sum('|// H|' in l for l in out_lines) != 1:
        failures.append('hexdump of the completed Ime.cool path did not print "// H"')
    if 'ERROR:' in text.split('STEP-CMD', 1)[-1]:
        failures.append('an ERROR: was printed: ' + re.search(r'ERROR:.*', text.split('STEP-CMD', 1)[-1]).group(0))
    if 'STEP-END' not in raw:
        failures.append('the shell did not finish the script')
    if failures:
        raise SystemExit('\n'.join(failures) + f'\nsee {d}/vm.log')
    print('cmdline-test: Unix-style command lines typed by parameter types, HolyC lines unchanged, '
          'Tab completion of symbols, file names and in strings, candidate lists PASS')


if __name__ == '__main__':
    main()
