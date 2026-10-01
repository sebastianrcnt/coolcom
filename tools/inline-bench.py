#!/usr/bin/env python3
"""Host benchmarks for coolc's small-function inlining (docs/coolc-inline.md).

Compiles coolc/tests/inline/Bench.cool (hand-written Cool helpers in a hot loop) and
coolc/tests/inline/BufferSum.warm (a Warm Buffer nth loop, through warmc) with the seed,
once as is and once with COOLC_NO_INLINE, runs each --repeat times and prints the best
wall-clock times. --before SEED.BIN adds a third build by another compiler image.
Usage: python3 tools/inline-bench.py [--repeat 5] [--before build/old-seed.BIN]
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/inline-bench'


def compile_cool(src, out, compiler, no_inline=False):
    text = src.read_text()
    if no_inline:
        text = '#define COOLC_NO_INLINE 1\n' + text
    cool = out.with_suffix('.cool')
    cool.write_text(text)
    env = dict(os.environ, COOLC_COMPILER_BIN=str(compiler))
    p = subprocess.run([str(ROOT / 'build/coolc'), str(cool), str(out)], cwd=ROOT, env=env, capture_output=True)
    assert p.returncode == 0 and b'Errs:0 ' in p.stdout, p.stdout.decode()[-2000:]


def best(binary, repeat):
    times, output = [], None
    for _ in range(repeat):
        start = time.perf_counter()
        p = subprocess.run([str(ROOT / 'build/coolc'), '--run', str(binary)], cwd=ROOT, capture_output=True, check=True)
        times.append(time.perf_counter() - start)
        assert output in (None, p.stdout), 'output differs between runs'
        output = p.stdout
    return min(times), output


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--repeat', type=int, default=5)
    ap.add_argument('--before', type=Path, help='another compiler image to compare (e.g. the previous seed)')
    args = ap.parse_args()
    subprocess.run(['make', '-s', 'build/coolc', 'build/warmc'], cwd=ROOT, check=True)
    OUT.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / 'coolc/tests/codegen/TestBase.coolh', OUT / 'TestBase.coolh')
    tests = ROOT / 'coolc/tests/inline'
    std = ROOT / 'warmc/standard/src'
    subprocess.run([str(ROOT / 'build/warmc'), 'compile', str(std / 'Buffer.warmh'), str(std / 'Buffer.warm'),
                    str(tests / 'BufferSum.warm'), '--entrypoint=Bench.BufferSum:main', '--target-type=hc',
                    '--output=' + str(OUT / 'BufferSum-src.cool')], cwd=ROOT, check=True)
    seed = ROOT / 'coolc/seed/Compiler.BIN'
    programs = [('Bench.cool', tests / 'Bench.cool'), ('BufferSum.warm', OUT / 'BufferSum-src.cool')]
    for name, src in programs:
        stem = Path(name).stem
        variants = [('no inlining', seed, True), ('inlining', seed, False)]
        if args.before:
            variants.insert(0, ('--before', args.before.resolve(), False))
        results = []
        for label, compiler, no_inline in variants:
            binary = OUT / f'{stem}-{label.strip("-").replace(" ", "-")}.BIN'
            compile_cool(src, binary, compiler, no_inline)
            results.append((label, *best(binary, args.repeat)))
        assert len({r[2] for r in results}) == 1, f'{name}: outputs differ'
        base = results[-2][1]
        for label, seconds, _ in results:
            print(f'{name:15} {label:12} {seconds:7.3f}s  x{base / seconds:.2f}')


if __name__ == '__main__':
    main()
