#!/usr/bin/env python3
"""Compare signed Pervasive calls/inlining with the same kernel and Vim.warm.

Build the kernel, VM and Warm package first, then run:
    python3 tools/warm-inline-perf.py build/kernel.Image --repeat 3
Only the generated build/warmcool/Kernel.cool is temporarily changed; it is
restored even on failure. Do not rebuild that package during this measurement.
Each workload verifies saved edits, a 330 KB jump and restored terminal focus.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('program_perf', Path(__file__).with_name('program-perf.py'))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel', type=Path)
    parser.add_argument('--repeat', type=int, default=3)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/warm-inline-perf')
    args = parser.parse_args()
    if args.repeat < 1:
        parser.error('--repeat must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    package = ROOT / 'build/warmcool/Kernel.cool'
    original = package.read_bytes()
    enabled = b'if (WPrefix(ty->name, "Int")) return WGOpenSigned(g, d, vals[0], vals[1], ty);'
    assert original.count(enabled) == 1, 'build the current Warm kernel package first'
    disabled = original.replace(enabled, b'if (WPrefix(ty->name, "Int")) return NULL;')
    kernel_digest = hashlib.sha256(args.kernel.read_bytes()).hexdigest()
    result = dict(kernel_sha256=kernel_digest, repeat=args.repeat, workload='unchanged Vim.warm; tools/program-perf.py warm variant; 640x480')
    try:
        for name, source in [('before', disabled), ('after', original)]:
            package.write_bytes(source)
            rows = []
            for trial in range(args.repeat):
                rows.append(perf.benchmark(args.kernel.resolve(), '90b47e3', 'warm'))
                logs = args.output / f'{name}-{trial + 1}'
                logs.mkdir(exist_ok=True)
                for filename in ['vm.log', 'input.txt', 'Perf.cool']:
                    (logs / filename).write_bytes((ROOT / 'build/program-perf/warm' / filename).read_bytes())
                assert package.read_bytes() == source, 'Warm package rebuilt during benchmark'
                assert hashlib.sha256(args.kernel.read_bytes()).hexdigest() == kernel_digest, 'kernel changed during benchmark'
            result[name] = dict(package_sha256=hashlib.sha256(source).hexdigest(), trials=rows,
                                median={key: statistics.median(row[key] for row in rows) for key in rows[0]})
            (args.output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    finally:
        package.write_bytes(original)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
