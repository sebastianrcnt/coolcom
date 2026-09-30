#!/usr/bin/env python3
"""Compile each C fixture and its generated Cool counterpart, then compare stdout."""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build' / 'c2hc-test'
TESTS = Path(__file__).resolve().parent / 'tests'
SEED = ROOT / 'coolc' / 'seed' / 'Compiler.BIN'
HOST = ROOT / 'build' / 'coolc'


def run(*args, env=None):
    return subprocess.run(args, cwd=ROOT, env=env, capture_output=True,
                          check=True, timeout=30)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    cases = sorted(TESTS.glob('*.c'))
    if not cases:
        raise RuntimeError('no C fixtures found')
    for source in cases:
        name = source.stem
        c_exe = OUT / (name + '.c.bin')
        hc = OUT / (name + '.cool')
        hc_bin = OUT / (name + '.BIN')
        run('clang', '-std=c11', '-O0', '-Wall', '-Wextra', str(source), '-o', str(c_exe))
        run(sys.executable, str(ROOT / 'tools' / 'c2hc' / 'c2hc.py'), str(source), str(hc))
        compile_env = os.environ.copy()
        compile_env['COOLC_COMPILER_BIN'] = str(SEED)
        hc_bin.unlink(missing_ok=True)
        compilation = run(str(HOST), str(hc), str(hc_bin), env=compile_env)
        if b'Errs:0 ' not in compilation.stdout or not hc_bin.is_file():
            raise RuntimeError(f'Cool compilation failed for {name}: '
                               f'{compilation.stdout.decode(errors="replace")} '
                               f'{compilation.stderr.decode(errors="replace")}')
        c_output = run(str(c_exe)).stdout
        hc_output = run(str(HOST), '--run', str(hc_bin)).stdout
        if c_output != hc_output:
            print(f'FAIL {name}: stdout differs', file=sys.stderr)
            print(f'C:    {c_output!r}\nCool: {hc_output!r}', file=sys.stderr)
            return 1
        print(f'PASS {name}')
    print(f'{len(cases)} C/Cool stdout comparisons passed')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr.decode(errors='replace'), file=sys.stderr)
        print(error, file=sys.stderr)
        sys.exit(1)
