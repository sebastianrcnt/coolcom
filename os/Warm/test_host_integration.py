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
