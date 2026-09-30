#!/usr/bin/env python3
"""Run portable OS examples against the host backend in an isolated directory."""
from pathlib import Path
import os
import subprocess
import tempfile
from os_modules import os_modules
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warm-os'
OUT.mkdir(parents=True, exist_ok=True)
# Host-only escape probes: both final and intermediate symlinks must be denied.
external = tempfile.TemporaryDirectory(prefix='warm-cap-outside-')
outside = Path(external.name)
(outside / 'secret').write_bytes(b'outside sentinel')
(OUT / 'CapRoot').mkdir(exist_ok=True)
for name, target in [('link', outside / 'secret'), ('escape', outside)]:
    link = OUT / 'CapRoot' / name
    if link.is_symlink(): link.unlink()
    link.symlink_to(target)
env = dict(os.environ, COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
for name in ['Files', 'Streams', 'Sockets', 'Tasks', 'Capabilities']:
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
assert (outside / 'secret').read_bytes() == b'outside sentinel'
for name in ['link', 'escape']: (OUT / 'CapRoot' / name).unlink()
external.cleanup()
print('OS: host files, streams, TCP/UDP, tasks and confined capabilities PASS')
