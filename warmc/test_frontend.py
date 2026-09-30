#!/usr/bin/env python3
"""Corpus syntax smoke test plus negative grammar and AST shape regressions."""
from pathlib import Path
import subprocess
import json

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/frontend-tests'
OUT.mkdir(parents=True, exist_ok=True)
CMD = [str(ROOT / 'build/coolc'), '--run', str(ROOT / 'build/warmcool/Warm.BIN')]


def run(path, dump=False):
    return subprocess.run([*CMD, '--dump-ast' if dump else '--parse', str(path)],
                          capture_output=True, timeout=10)


sources = sorted((ROOT / 'warmc/test-programs').rglob('*.warm*'))
sources += sorted((ROOT / 'warmc/builtin').glob('*.warm*'))
sources += sorted((ROOT / 'warmc/standard').rglob('*.warm*'))
failures = []
for path in sources:
    p = run(path)
    if p.returncode:
        failures.append((str(path.relative_to(ROOT)), p.stdout.decode(), p.stderr.decode()))

negative = [
    'module body Test is function f(): Unit is return nil; end; end module body. junk',
    'module body Test is function f(): Unit is let x: Int64 := 1 + 2 * 3; return nil; end; end module body.',
    'module body Test is type Hidden: Free; end module body.',
    'module body Test is function f(): Unit is if true then end if; return nil; end; end module body.',
    'module body Test is constant x: Int64 := #b2; end module body.',
    'module body Test is constant x: String := "unterminated',
    'module body Test is constant x: String := """unterminated',
    'module body Test is function f(): Unit is 1 := 2; end; end module body.',
    'module body Test is function f(): Unit is f(x => 1, 2); end; end module body.',
]
for i, source in enumerate(negative):
    path = OUT / f'negative-{i}.warm'
    path.write_text(source)
    p = run(path)
    if p.returncode != 1 or b'Parse Error:' not in p.stdout or b'^' not in p.stdout:
        failures.append((str(path), p.stdout.decode(), p.stderr.decode()))
path = OUT / 'shape.warm'
path.write_text('module body Test is function f(x: Int64): Int64 is return (x + 1) * 2; end; end module body.')
p = run(path, True)
assert p.returncode == 0, p.stdout
assert b'value binary *\n     left binary +\n' in p.stdout, p.stdout
report = dict(sources=len(sources), negative_cases=len(negative), ast_checks=1, failures=failures)
(OUT / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
raise SystemExit(bool(failures))
