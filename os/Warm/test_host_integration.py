#!/usr/bin/env python3
"""CoolOS modules are discoverable only through explicit integration options."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
WARM = ROOT / 'tools/warm'
sources = ROOT / 'os/Warm/standard/src'
p = subprocess.run([WARM, 'check', sources], capture_output=True, text=True)
assert p.returncode == 2 and 'requires --coolos' in p.stderr, p.stdout + p.stderr
subprocess.run([WARM, 'check', sources, '--coolos'], check=True)
print('CoolOS: explicit module discovery and interfaces PASS')

# Keep real application compatibility checks on the CoolOS side of the toolchain.
for name in ['Top', 'Vim', 'Tmux']:
    subprocess.run([WARM, 'check', ROOT / f'os/Disk/{name}.warm', '--coolos'], check=True)
print('CoolOS: Top, Vim and Tmux language compatibility PASS')
