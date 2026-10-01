#!/usr/bin/env python3
"""Top (os/Disk/Top.cool): the task monitor, driven by typed keys. Two tasks are started on core 1, a
busy one (Burner: computes, yields) and a sleeping one (Napper); Top must list both with their core,
show the busy one with a high CPU share and the sleeping one with a low one, list the FAT32 free space
(compared with mtools' `mdir`), sort by name, and kill the selected task on `k`,`y`."""
import re
import subprocess
import sys

import testvm
from testvm import ROOT


KEY_DOWN = 108


def line(s, wait=500):
    return testvm.typed(s + '\n') + f'delay {wait}\n'


def strip(s):
    return re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', s)


def main():
    d = ROOT / 'build/top-test'
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk, 64 * 1024 * 1024, label='TOPTEST')
    testvm.install_disk_files(disk)
    free_bytes = int(re.search(r'([\d ]+) bytes free', subprocess.run(
        ['mdir', '-i', str(disk), '::'], check=True, capture_output=True, text=True).stdout).group(1).replace(' ', ''))
    script = testvm.BOOT
    script += line('U0 Napper(U8 *d) {while (TRUE) Sleep(50);}')
    script += line('U0 Burner(U8 *d) {I64 i; while (TRUE) {for (i = 0; i < 5000000; i++) {} Yield;}}')
    script += line('Spawn(&Napper, 0, "Napper", 1); Spawn(&Burner, 0, "Burner", 1);', 800)
    script += line('Top;', 3500)
    script += testvm.typed('n') + 'delay 1500\n'                    # sort by name: Adam Burner Display Napper Seth1 Shell
    script += f'1 {KEY_DOWN} 1\n1 {KEY_DOWN} 0\ndelay 200\n' * 3   # select Napper (GPU display worker precedes it)
    script += 'delay 1200\n' + testvm.typed('k') + 'delay 300\n' + testvm.typed('y') + 'delay 2500\n'
    script += testvm.typed('q') + 'delay 400\n'
    script += line('Print("\\nTOPDONE%d\\n", 1);') + testvm.finish('TOPDONE1')
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(sys.argv[1], no_venus=True, timeout=45, input_script=d / 'input.txt', disk=disk,
        size=(640, 480), host_timeout=60), d / 'vm.log')
    raw = (d / 'vm.log').read_text(errors='replace')
    testvm.check_init_log(raw)
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
