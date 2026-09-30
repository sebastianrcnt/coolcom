#!/usr/bin/env python3
"""Real kernel -> MMIO -> split queue -> opt-in stub; no Vulkan dependencies."""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/venus-transport-test'
OUT.mkdir(parents=True, exist_ok=True)
image = sys.argv[1]

for name, options, marker in [('stub', ['--gpu-3d-stub'], 'VENUS PASS 1'),
                               ('2d', ['--no-venus'], 'VENUS SKIP 1'),
                               ('default', [], 'VENUS SKIP 1'),
                               ('no-gpu', ['--no-gpu'], 'VENUS SKIP 1')]:
    disk = OUT / f'{name}.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '::'], check=True)
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(ROOT / 'tools/venus/transport-test.cool'), '::Init.cool'], check=True)
    script = OUT / f'{name}.input'
    script.write_text(f'wait {marker}\nwait C:/> \nquit\n')
    logfile = OUT / f'{name}.log'
    with logfile.open('wb') as out:
        proc = subprocess.run(['build/coolvm', '--headless', '--cpus', '2', '--mem', '1024',
                               '--timeout', '25', '--disk', str(disk), '--input-script', str(script),
                               *options, image], cwd=ROOT, stdout=out, stderr=subprocess.STDOUT, timeout=35)
    log = logfile.read_text(errors='replace')
    assert proc.returncode == 0 and marker in log, f'{name}: {logfile}\n{log[-4000:]}'
    assert not any(x in log.split('SELFTEST PASS', 1)[-1] for x in ['ERROR:', 'Exception:', 'VENUS FAIL', 'heap overflow', 'Free: bad pointer']), log
    commands = re.findall(r'gpu-3d-stub: cmd=([0-9a-f]+) ctx=(\d+) ring=(\d+) fence=(\d+) result=([0-9a-f]+)', log)
    if name == 'stub':
        types = [c[0] for c in commands]
        assert types[:3] == ['0108', '0109', '0200'], types
        assert commands[3][4] == '1205' and commands[4][4] == '1102' and commands[5][4] == '1205'
        for cmd in ['010c', '0202', '0203', '0207', '0208', '0209', '010d', '0201']:
            assert cmd in types, (cmd, types)
        submits = [c for c in commands if c[0] == '0207' and c[1] == '1']
        assert len(submits) == 40 and [int(c[2]) for c in submits] == [i % 2 for i in range(40)]
        assert all(c[1] == '1' and c[4] == '1100' for c in submits)
        fences = [int(c[3]) for c in commands]
        assert fences == sorted(set(fences)), fences
        assert all(c[4].startswith('11') for i, c in enumerate(commands) if i not in (3, 5)), commands
    else:
        assert not commands, f'{name}: unexpected 3D commands'
    print(f'venus-transport-test: {name} PASS')
