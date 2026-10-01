#!/usr/bin/env python3
"""Compile/run the same access workloads with two Warm compiler BINs and one Cool seed.
Usage: tools/warm-access-perf.py build/stage7-before-Warm.BIN build/warmcool/Warm.BIN --repeat 3
Timings exclude loading/compilation/allocation; each result must sum 16,777,216 elements.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/stage7-access-perf')
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error('--repeat must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    source = args.output / 'Access.warm'
    source.write_text((ROOT / 'warmc/perf/Access.warm').read_text().replace('"BYTE_SCAN_INPUT"', '"' + 'x' * 16384 + '"'))
    env = dict(os.environ, COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
    library = ROOT / 'warmc/standard/src/Buffer'
    modules = str(library.with_suffix('.warmh')) + ',' + str(library.with_suffix('.warm'))
    result = dict(repeat=args.repeat, cool_seed_sha256=hashlib.sha256((ROOT / 'coolc/seed/Compiler.BIN').read_bytes()).hexdigest())
    for label, compiler in [('before', args.before), ('after', args.after)]:
        code, binary = args.output / (label + '.cool'), args.output / (label + '.BIN')
        subprocess.run([str(ROOT / 'build/coolc'), '--run', str(compiler.resolve()), 'compile', modules, str(source.resolve()), '--entrypoint=Access:main', '--output=' + str(code.resolve())], env=env, check=True, capture_output=True)
        p = subprocess.run([str(ROOT / 'build/coolc'), str(code.resolve()), str(binary.resolve())], env=env, check=True, capture_output=True)
        (args.output / (label + '-compile.log')).write_bytes(p.stdout + p.stderr)
        trials = []
        for trial in range(args.repeat):
            p = subprocess.run([str(ROOT / 'build/coolc'), '--run', str(binary.resolve())], env=env, check=True, capture_output=True, timeout=60)
            (args.output / f'{label}-{trial + 1}.log').write_bytes(p.stdout + p.stderr)
            values = list(map(int, p.stdout.split()))
            assert values[::2] == [16777216] * 3 and not p.stderr, p
            trials.append(dict(zip(['buffer_sum_ms', 'byte_scan_ms', 'matrix_2d_ms'], values[1::2])))
        result[label] = dict(compiler_sha256=hashlib.sha256(compiler.read_bytes()).hexdigest(), generated_bytes=code.stat().st_size, trials=trials,
                             median={key: statistics.median(row[key] for row in trials) for key in trials[0]})
    (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
