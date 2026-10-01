#!/usr/bin/env python3
"""Reproducible Warm library microbenchmarks; save raw samples and medians."""
from pathlib import Path
import json
import os
import platform
import statistics
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'warmc'))
from stdlib_modules import library_modules
OUT = ROOT / 'build/warm-stdlib-perf'
OUT.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, WARM_TOOLCHAIN_READY='1')
std = ROOT / 'warmc/standard/src'
source = ROOT / 'warmc/perf/stdlib/Bench.warm'
code, binary = OUT / 'Bench.cool', OUT / 'Bench.BIN'
subprocess.run([ROOT / 'tools/warm', 'compile', *library_modules(ROOT),
                std / 'OS/Time.warm', source, '--entrypoint=StdlibBench:main',
                '--output=' + str(code)], check=True, env=env)
subprocess.run([ROOT / 'tools/warm', 'build', code, '-o', binary],
               check=True, capture_output=True, env=env)
p = subprocess.run([ROOT / 'tools/warm', 'run', binary],
                   check=True, capture_output=True, text=True, timeout=120, env=env)
(OUT / 'samples.csv').write_text('operation,n,milliseconds,checksum\n' + p.stdout)
groups = {}
checksums = {}
for line in p.stdout.splitlines():
    name, n, elapsed, checksum = line.split(',')
    key = name + ':' + n
    groups.setdefault(key, []).append(int(elapsed))
    checksums.setdefault(key, set()).add(int(checksum))
assert all(len(values) == 5 for values in groups.values()), groups
assert all(len(values) == 1 for values in checksums.values()), checksums
cpu = subprocess.run(['sysctl', '-n', 'machdep.cpu.brand_string'], capture_output=True, text=True).stdout.strip()
report = dict(cpu=cpu, platform=platform.platform(), backend='Warm host native (coolc arm64)',
              timer='OS.Time.monotonicMs; whole milliseconds', repetitions=5,
              note='Allocation/growth included for push/insert; construction and validation excluded for sort; no process startup time.',
              benchmarks={key: dict(samples_ms=values, median_ms=statistics.median(values),
                                    checksum=next(iter(checksums[key]))) for key, values in groups.items()})
(OUT / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
