#!/usr/bin/env python3
"""Boot a scripted Vim session and verify its FAT32 write from the host."""
import pathlib
import re
import subprocess
import sys
import tempfile

KEYS = {}
for first, lo, up in ((2, "1234567890-=", "!@#$%^&*()_+"),
                      (16, "qwertyuiop[]", "QWERTYUIOP{}"),
                      (30, "asdfghjkl;'", 'ASDFGHJKL:"'),
                      (44, "zxcvbnm,./", "ZXCVBNM<>?")):
    for i, (plain, shifted) in enumerate(zip(lo, up)):
        KEYS[plain] = (first + i, False)
        KEYS[shifted] = (first + i, True)


def keys_of(code):
    return f"1 {code} 1\n1 {code} 0\n"


def typed(line):
    result = ''
    for ch in line:
        code, shift = KEYS[ch]
        if shift:
            result += '1 42 1\n'
        result += keys_of(code)
        if shift:
            result += '1 42 0\n'
    return result + keys_of(28)


def check_init_log(log):
    marker = 'Running C:/Init.HC\n'
    if marker not in log:
        raise AssertionError('shell did not run C:/Init.HC')
    after_init = log.split(marker, 1)[1]
    prompt = re.search(r'(?m)^> ', after_init)
    if not prompt:
        raise AssertionError('shell did not reach a prompt after C:/Init.HC')
    diagnostics = re.findall(r'^(?:ERROR|WARNING):.*$', after_init[:prompt.start()], re.MULTILINE)
    if diagnostics:
        raise AssertionError('C:/Init.HC diagnostics:\n' + '\n'.join(diagnostics))


def main():
    with tempfile.TemporaryDirectory() as td:
        d = pathlib.Path(td)
        disk = d / 'disk.img'
        with disk.open('wb') as f:
            f.truncate(40 * 1024 * 1024)
        subprocess.run(['newfs_msdos', '-F', '32', '-S', '512', '-c', '1', '-s', '81920',
                        '-h', '16', '-u', '63', '-v', 'VIMTEST', str(disk)], check=True,
                       capture_output=True)
        for name in ('Init.HC', 'Vim.HC', 'Tmux.HC', 'Nyan.HC'):
            subprocess.run(['mcopy', '-i', str(disk), 'os/Disk/' + name, '::' + name],
                           check=True, capture_output=True)
        source = d / 'sample.txt'
        source.write_bytes(b'abc\n')
        subprocess.run(['mcopy', '-i', str(disk), str(source), '::Sample.txt'],
                       check=True, capture_output=True)
        script = d / 'input.txt'
        script.write_text('delay 3500\n' + typed('Vim("C:/Sample.txt");') +
                          'delay 1500\n' + keys_of(23) + '1 42 1\n' + keys_of(45) + '1 42 0\n' +
                          keys_of(1) + typed(':wq'))
        log = d / 'vm.log'
        with log.open('wb') as out:
            subprocess.run(['gtimeout', '-k', '2', '25', 'build/coolvm', '--headless',
                            '--cpus', '2', '--mem', '1024', '--timeout', '17',
                            '--input-script', str(script), '--disk', str(disk),
                            sys.argv[1]], stdout=out, stderr=subprocess.STDOUT)
        check_init_log(log.read_text(errors='replace'))
        got = subprocess.run(['mcopy', '-n', '-i', str(disk), '::Sample.txt', '-'],
                             check=True, capture_output=True).stdout
        if got != b'Xabc\n':
            print(log.read_text(errors='replace')[:2500])
            raise AssertionError(f'Vim wrote {got!r}, expected b"Xabc\\n"')
        print('Vim FAT32 edit test passed')


if __name__ == '__main__':
    main()
