#!/usr/bin/env python3
"""Run portable OS examples against the host backend in an isolated directory."""
from pathlib import Path
import os
import subprocess
from os_modules import os_modules
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warm-os'
OUT.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
for name in ['Files', 'Streams', 'Sockets']:
    code = OUT / (name + '.cool')
    binary = OUT / (name + '.BIN')
    subprocess.run([ROOT / 'build/warmc', 'compile', *os_modules(ROOT),
        ROOT / ('warmc/examples/kernel/' + name + '.warm'), '--entrypoint=' + name + ':main',
        '--output=' + str(code)], check=True, env=env)
    p = subprocess.run([ROOT / 'build/coolc', code, binary], check=True, capture_output=True, env=env)
    assert b'Errs:0 ' in p.stdout, p.stdout
    p = subprocess.run([ROOT / 'build/coolc', '--run', binary], cwd=OUT, check=True, capture_output=True)
    assert p.stdout == ('WARM ' + ('FILE' if name == 'Files' else name.upper()) + ' PASS\n').encode(), p.stdout
    assert (OUT / 'Warm.txt').read_bytes() == b'Warm FAT32\n'
print('OS: host files, streams, directory snapshots and TCP/UDP loopback PASS')
