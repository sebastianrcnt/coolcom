#!/usr/bin/env python3
"""Check the entire standard library and its tests, including interface-only imports."""
from pathlib import Path
import json
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/standard'
OUT.mkdir(parents=True, exist_ok=True)
standard = ROOT / 'warmc/standard'
modules = re.findall(r'(?:src|test)/[^\s]+\.warm', (standard / 'Makefile').read_text().split('TEST_BIN')[0])
from os_modules import os_modules
paths = [','.join(str(standard / name) for name in pair.split(',')) for pair in modules]
paths += os_modules(ROOT)[3:]
env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'),
           COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
cmd = [ROOT / 'build/coolc', '--run', ROOT / 'build/warmcool/Warm.BIN', '--check', *paths]
p = subprocess.run(list(map(str, cmd)), cwd=OUT, env=env, capture_output=True, timeout=30)
(OUT / 'cool.stdout').write_bytes(p.stdout)
(OUT / 'cool.stderr').write_bytes(p.stderr)
assert p.returncode == 0, (p.stdout, p.stderr)
report = dict(module_pairs=len(modules), sources=2 * len(modules), semantic_checks='PASS',
              note='Portable OS APIs and upstream compatibility modules checked.')
(OUT / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
