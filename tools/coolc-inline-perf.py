#!/usr/bin/env python3
"""Vim/Tmux latency (tools/program-perf.py, warm variant) with and without coolc inlining.

"before": a kernel Image built with COOLC_NO_INLINE (build/noinline/kernel.Image) and the
Warm package defining COOLC_NO_INLINE before the guest compiles the Warm runtime and
programs; "after": build/kernel.Image and the package as built. Same revision and seed.
Build the kernel, VM and Warm package first, then run:
    python3 tools/coolc-inline-perf.py --repeat 3
os/Kernel/Kernel.cool and build/warmcool/Kernel.cool are changed temporarily and
restored even on failure. Results: build/coolc-inline-perf/results.json.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('program_perf', Path(__file__).with_name('program-perf.py'))
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--repeat', type=int, default=3)
    args = parser.parse_args()
    out = ROOT / 'build/coolc-inline-perf'
    out.mkdir(parents=True, exist_ok=True)
    kernel_src = ROOT / 'os/Kernel/Kernel.cool'
    package = ROOT / 'build/warmcool/Kernel.cool'
    kernel_text, package_text = kernel_src.read_bytes(), package.read_bytes()
    runtime = b'ShellExe(WGCat(u, WKernelRuntime(u), "\\nWKernelComplete();\\n"));'
    assert package_text.count(runtime) == 1, 'build the current Warm kernel package first'
    try:
        kernel_src.write_bytes(b'#define COOLC_NO_INLINE 1\n' + kernel_text)
        subprocess.run(['make', '-s', 'B=build/noinline', 'build/noinline/kernel.Image'], cwd=ROOT, check=True)
    finally:
        kernel_src.write_bytes(kernel_text)
    result = dict(repeat=args.repeat, workload='tools/program-perf.py warm variant (Vim.warm, Tmux); 640x480')
    variants = [('before', ROOT / 'build/noinline/kernel.Image',
                 package_text.replace(runtime, b'ShellExe(WGCat(u, "#define COOLC_NO_INLINE 1\\n", WGCat(u, WKernelRuntime(u), "\\nWKernelComplete();\\n")));')),
                ('after', ROOT / 'build/kernel.Image', package_text)]
    try:
        for name, image, source in variants:
            package.write_bytes(source)
            rows = [perf.benchmark(image, 'HEAD', 'warm') for _ in range(args.repeat)]
            result[name] = dict(trials=rows, median={key: statistics.median(row[key] for row in rows) for key in rows[0]})
            (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    finally:
        package.write_bytes(package_text)
    result['ratio'] = {key: result['after']['median'][key] / value for key, value in result['before']['median'].items()}
    (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(before=result['before']['median'], after=result['after']['median'], ratio=result['ratio']), indent=2))


if __name__ == '__main__':
    main()
