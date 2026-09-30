#!/usr/bin/env python3
"""Top (os/Disk/Top.cool): the task monitor, driven by typed keys. Two tasks are started on core 1, a
busy one (Burner: computes, yields) and a sleeping one (Napper); Top must list both with their core,
show the busy one with a high CPU share and the sleeping one with a low one, list the FAT32 free space
(compared with mtools' `mdir`), sort by name, and kill the selected task on `k`,`y`."""
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
KEY_DOWN = 108


def line(s, wait=500):
    return vim.typed(s + '\n') + f'delay {wait}\n'


def strip(s):
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)


def main():
    d = ROOT / 'build/top-test'
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '-v', 'TOPTEST', '::'], check=True)
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True)
    free_bytes = int(re.search(r'([\d ]+) bytes free', subprocess.run(
        ['mdir', '-i', str(disk), '::'], check=True, capture_output=True, text=True).stdout).group(1).replace(' ', ''))
    script = vim.BOOT
    script += line('U0 Napper(U8 *d) {while (TRUE) Sleep(50);}')
    script += line('U0 Burner(U8 *d) {I64 i; while (TRUE) {for (i = 0; i < 5000000; i++) {} Yield;}}')
    script += line('Spawn(&Napper, 0, "Napper", 1); Spawn(&Burner, 0, "Burner", 1);', 800)
    script += line('Top;', 3500)
    script += vim.typed('n') + 'delay 1500\n'                    # sort by name: Adam Burner Display Napper Seth1 Shell
    script += f'1 {KEY_DOWN} 1\n1 {KEY_DOWN} 0\ndelay 200\n' * 3   # select Napper (GPU display worker precedes it)
    script += 'delay 1200\n' + vim.typed('k') + 'delay 300\n' + vim.typed('y') + 'delay 2500\n'
    script += vim.typed('q') + 'delay 400\n'
    script += line('Print("\\nTOPDONE%d\\n", 1);') + vim.finish('TOPDONE1')
    (d / 'input.txt').write_text(script)
    with (d / 'vm.log').open('wb') as out:
        subprocess.run(['gtimeout', '-k', '2', '60', 'build/coolvm', '--headless', '--cpus', '2', '--mem', '1024',
                        '--timeout', '45', '--width', '640', '--height', '480', '--input-script', str(d / 'input.txt'),
                        '--disk', str(disk), sys.argv[1]], stdout=out, stderr=subprocess.STDOUT)
    raw = (d / 'vm.log').read_text(errors='replace')
    vim.check_init_log(raw)
    after = raw.split('Running C:/Init.cool', 1)[-1]
    assert 'ERROR:' not in after and 'Exception:' not in after, f'guest error; see {d}/vm.log'
    failures = []
    if 'TOPDONE1' not in raw:
        failures.append('the shell did not come back after q')
    top = raw.split('\x1b[?1049h', 1)[-1].split('\x1b[?1049l', 1)[0]
    frames = [strip(f.replace('\x1b[K', '')) for f in top.split('\x1b[1;1H')[1:]]
    if len(frames) < 4:
        failures.append(f'only {len(frames)} frames')
    # Rows look like "     5    1 SLEEP     0.0  ...  Napper": task core state cpu% switches stack name.
    def rows(frame):
        out = {}
        for m in re.finditer(r'\s(\d+)\s+(\d+) (RUN|READY|SLEEP|STOP|KILL)\s+(\d+)\.(\d)\s+\d+\s+\d+K\s+(\w+)', frame):
            out[m.group(6)] = (int(m.group(1)), int(m.group(2)), m.group(3), int(m.group(4)) + int(m.group(5)) / 10)
        return out
    seen = [rows(f) for f in frames]
    both = [r for r in seen if 'Burner' in r and 'Napper' in r]
    if not both:
        failures.append('no frame lists Burner and Napper')
    else:
        r = both[-1] if 'Napper' in seen[-1] else both[len(both) // 2]
        if r['Burner'][1] != 1 or r['Napper'][1] != 1:
            failures.append(f'tasks are not on core 1: {r}')
        if r['Burner'][3] < 10:
            failures.append(f'Burner shows {r["Burner"][3]}% CPU')
        if r['Napper'][3] > 5 or r['Napper'][2] not in ('SLEEP', 'READY'):
            failures.append(f'Napper shows {r["Napper"]}')
        if not (r['Burner'][3] > r['Napper'][3]):
            failures.append('the busy task does not have more CPU than the sleeping one')
    # Sorted by CPU (default) the busy task is above the sleeping one in the first frame that has both.
    first = next((f for f in frames if 'Burner' in f and 'Napper' in f), '')
    if first and first.index('Burner') > first.index('Napper'):
        failures.append('CPU sort did not put Burner first')
    # Sorted by name after n.
    named = [f for f in frames if 'sort: name' in f and 'Napper' in f]
    if not named or not (named[-1].index('Adam') < named[-1].index('Burner') < named[-1].index('Napper') < named[-1].index('Seth1')):
        failures.append('name sort order wrong')
    if 'Kill task' not in top or 'Napper? (y/n)' not in strip(top):
        failures.append('no kill prompt for Napper')
    if 'Napper' in seen[-1] or 'Burner' not in seen[-1]:
        failures.append(f'after k y the last frame still lists Napper (or lost Burner): {sorted(seen[-1])}')
    m = re.search(r'Disk C: FAT32\s+free ([\d.]+) (MB|GB|KB) of', strip(top))
    if not m:
        failures.append('no FAT32 line')
    else:
        shown = float(m.group(1)) * {'KB': 1 << 10, 'MB': 1 << 20, 'GB': 1 << 30}[m.group(2)]
        if abs(shown - free_bytes) > 200 * 1024:
            failures.append(f'Top says {shown:.0f} bytes free, mdir {free_bytes}')
    for word in ('Core 0', 'Core 1', 'Heap', 'blocks'):
        if word not in strip(top):
            failures.append(f'missing {word!r}')
    if failures:
        raise SystemExit('\n'.join(failures) + f'\nsee {d}/vm.log')
    print('top-test: tasks per core with state and CPU share, heap and FAT32 lines, sort by name and kill PASS')


if __name__ == '__main__':
    main()
