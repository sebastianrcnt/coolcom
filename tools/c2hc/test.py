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
        run(os.environ.get('CC', 'cc'), '-std=c11', '-O0', '-ffp-contract=off',
            '-Wall', '-Wextra', str(source), '-lm', '-o', str(c_exe))
        run(sys.executable, str(ROOT / 'tools' / 'c2hc' / 'c2hc.py'), str(source), str(hc))
        compile_env = os.environ.copy()
        compile_env['COOLC_COMPILER_BIN'] = str(SEED)
        c_output = run(str(c_exe)).stdout
        targets = [('arm64', HOST)]
        if name.startswith('float32'):
            targets.append(('x86_64', ROOT / 'build/coolc-x86_64'))
        for target, host in targets:
            hc_bin = OUT / (name + '.' + target + '.BIN')
            hc_bin.unlink(missing_ok=True)
            compilation = run(str(HOST), '--target', target, str(hc), str(hc_bin), env=compile_env)
            if b'Errs:0 ' not in compilation.stdout or not hc_bin.is_file():
                raise RuntimeError(f'Cool compilation failed for {name}/{target}: '
                                   f'{compilation.stdout.decode(errors="replace")} '
                                   f'{compilation.stderr.decode(errors="replace")}')
            hc_output = run(str(host), '--run', str(hc_bin)).stdout
            if c_output != hc_output:
                print(f'FAIL {name}/{target}: stdout differs', file=sys.stderr)
                print(f'C:    {c_output!r}\nCool: {hc_output!r}', file=sys.stderr)
                return 1
            print(f'PASS {name}/{target}')
    for name, source, diagnostic in [
        ('fma', '#include <math.h>\nint main(void) {return fma(1, 2, 3);}', 'single-rounding'),
        ('fmaf', '#include <math.h>\nint main(void) {return fmaf(1, 2, 3);}', 'single-rounding'),
        ('builtin_fmaf', 'int main(void) {return __builtin_fmaf(1, 2, 3);}', 'single-rounding'),
        ('native_float', 'extern float native(float);\nint main(void) {return native(1);}', 'native C float ABI'),
        ('long_double', 'int main(void) {long double x = 1; return x;}', 'long double'),
    ]:
        path = OUT / (name + '.unsupported.c')
        path.write_text(source)
        result = subprocess.run([sys.executable, str(ROOT / 'tools/c2hc/c2hc.py'),
                                 str(path), str(OUT / (name + '.cool'))],
                                capture_output=True, text=True, timeout=30)
        if result.returncode == 0 or diagnostic not in result.stderr:
            raise RuntimeError(f'{name}: expected rejection containing {diagnostic!r}: {result.stderr}')
        print(f'PASS unsupported {name}')
    print(f'{len(cases)} C/Cool stdout comparisons passed')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout.decode(errors='replace'), file=sys.stderr)
            print(error.stderr.decode(errors='replace'), file=sys.stderr)
        print(error, file=sys.stderr)
        sys.exit(1)
