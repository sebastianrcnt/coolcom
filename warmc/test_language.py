#!/usr/bin/env python3
"""Stage 6 execution, diagnostics, ownership edges and checked arithmetic regressions."""
from pathlib import Path
import json
import os
import random
import subprocess
from stdlib_modules import library_modules

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/language-tests'
OUT.mkdir(parents=True, exist_ok=True)
ENV = dict(os.environ, COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
LIBRARY = library_modules(ROOT)
checks = []


def run(cmd, label):
    p = subprocess.run(list(map(str, cmd)), capture_output=True, env=ENV, timeout=60)
    (OUT / (label + '.log')).write_bytes(p.stdout + p.stderr)
    return p


def program(body, decls=''):
    return f'module body Test is {decls} function main(): ExitCode is {body} return ExitSuccess(); end; end module body.'


def execute(source, label, expected=None, trap=None, library=()):
    if isinstance(source, str):
        path = OUT / (label + '.warm')
        path.write_text(source)
    else:
        path = source
    code, binary = OUT / (label + '.cool'), OUT / (label + '.BIN')
    p = run([ROOT / 'tools/warm', 'compile', *library, path, '--entrypoint=' + ('Stage6:main' if path.name == 'Stage6.warm' else 'Test:main'), '--output=' + str(code)], label + '-warm')
    assert p.returncode == 0, p.stdout + p.stderr
    p = run([ROOT / 'build/coolc', code, binary], label + '-cool')
    assert p.returncode == 0 and b'Errs:0 ' in p.stdout, p.stdout + p.stderr
    p = run([ROOT / 'build/coolc', '--run', binary], label + '-run')
    if trap:
        assert p.returncode != 0 and trap.encode() in p.stderr, (label, p.stdout, p.stderr)
    else:
        assert p.returncode == 0 and p.stdout == expected and not p.stderr, (label, p.returncode, p.stdout, p.stderr)
    checks.append(label)
    return code.read_text()


execute(ROOT / 'warmc/language-tests/Stage6.warm', 'features', b'STAGE 6 PASS\n', library=LIBRARY)
negatives = {
    'break-outside': 'break;',
    'continue-outside': 'continue;',
    'unknown-label': 'while true do break missing; end while;',
    'duplicate-label': 'while x: true do while x: true do break; end while; break; end while;',
    'float-remainder': 'let x: Float64 := 1.5; printLn(x % x);',
    'assign-call-field': 'pair().x := 1;',
    'linear-call-field': 'printLn(owned().x);',
    'exit-local-leak': 'while true do let value: Owned := Owned(x => 1); break; end while;',
    'continue-local-leak': 'while true do let value: Owned := Owned(x => 1); continue; end while;',
    'exit-outer-move': 'let value: Owned := Owned(x => 1); while true do let {x: Int64} := value; break; end while; let {x as y: Int64} := value;',
    'continue-outer-move': 'let value: Owned := Owned(x => 1); while true do let {x: Int64} := value; continue; end while; let {x as y: Int64} := value;',
    'label-local-leak': 'while target: true do let value: Owned := Owned(x => 1); while true do break target; end while; let {x: Int64} := value; end while;',
}
decls = 'record Owned: Linear is x: Int64; end; record Pair: Free is x: Int64; end; function owned(): Owned is return Owned(x => 1); end; function pair(): Pair is return Pair(x => 1); end;'
for label, body in negatives.items():
    path = OUT / (label + '.warm')
    path.write_text(program(body, decls))
    p = run([ROOT / 'tools/warm', 'compile', path, '--check'], label)
    assert p.returncode == 1 and b'Error' in p.stdout + p.stderr, (label, p.stdout, p.stderr)
    checks.append(label)
for i, escape in enumerate([r'\x', r'\x1', r'\xGG', r'\u{}', r'\u{d800}', r'\u{dfff}', r'\u{110000}', r'\u{1234567}', r'\u{zz}', r'\u123']):
    path = OUT / f'escape-{i}.warm'
    path.write_text(program(f'printLn("{escape}");'))
    p = run([ROOT / 'tools/warm', 'compile', path, '--parse'], f'escape-{i}')
    assert p.returncode == 1 and b'Parse Error' in p.stdout + p.stderr, p.stdout + p.stderr
    checks.append(f'escape-{i}')
# Runtime operands prevent constant folding. Compare valid random/boundary signed results.
rng = random.Random(6)
lines, expected = [], []
for bits in [8, 16, 32, 64]:
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    pairs = [(lo, 0), (hi, 0), (lo, 1), (hi, -1), (lo, hi), (0, lo), (-7, 3), (7, -3), (-7, -3)]
    pairs += [(rng.randint(lo, hi), rng.randint(lo, hi)) for _ in range(16)]
    for j, (a, b) in enumerate(pairs):
        left, right = f'a{bits}_{j}', f'b{bits}_{j}'
        lines += [f'let {left}: Int{bits} := {a}; let {right}: Int{bits} := {b};']
        for op in ['+', '-', '*', '/', '%']:
            if op in ['/', '%'] and (b == 0 or (a == lo and b == -1)):
                continue
            q = (abs(a) // abs(b)) * (-1 if (a < 0) != (b < 0) else 1) if b else 0
            value = {'+': a + b, '-': a - b, '*': a * b, '/': q, '%': a - q*b}[op]
            if lo <= value <= hi:
                lines.append(f'printLn({left} {op} {right});')
                expected.append(str(value))
text = execute(program(' '.join(lines)), 'signed-results', ('\n'.join(expected) + '\n').encode())
assert 'Overflow in trappingAdd (Int64)' in text and 'Overflow in trappingMultiply (Int64)' in text
# No emitted Pervasive trapping arithmetic calls in this monomorphic signed workload.
assert text.count('Overflow in trappingAdd (Int64)') > 1
for bits in [8, 16, 32, 64]:
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    for label, a, b, op, message in [
        ('add', hi, 1, '+', 'Overflow in trappingAdd'),
        ('sub', lo, 1, '-', 'Overflow in trappingSubtract'),
        ('mul', lo, -1, '*', 'Overflow in trappingMultiply'),
        ('div', lo, -1, '/', 'Overflow in trappingDivide'),
        ('rem', lo, -1, '%', 'Overflow in rem'),
        ('div-zero', 7, 0, '/', 'Division by zero'),
        ('rem-zero', 7, 0, '%', 'Division by zero'),
    ]:
        execute(program(f'let a: Int{bits} := {a}; let b: Int{bits} := {b}; printLn(a {op} b);'), f'{label}-{bits}', trap=message)
# Discharged local resources, including labelled exits from nested branches, remain legal.
execute(program('while outer: true do let value: Owned := Owned(x => 1); let {x: Int64} := value; while true do break outer; end while; end while; printLn("released");', 'record Owned: Linear is x: Int64; end;'), 'discharged-exit', b'released\n')
for label, expr in [('reversed-slice', 'sliceSpan("abc", 2, 1)'), ('past-end-slice', 'sliceSpan("abc", 0, 4)')]:
    execute(program(f'printLn(spanLength({expr}));'), label, trap='invalid half-open bounds')
for i, template in enumerate(['{', '}', '{:q}', '{} {}', '', '{:s}', '{:d', '{:00s}']):
    src = 'import Standard.Buffer(Buffer, allocateEmpty, insertBack, slice, destroyFree); import Standard.String(String,destroyString); import Standard.Format(FormatArg,Signed,format); ' + program(f'var args: Buffer[FormatArg[Static]] := allocateEmpty(); insertBack(&!args,Signed(value => 3)); let result: String := format("{template}",slice(&args,0,1)); destroyString(result); destroyFree(args);')
    execute(src, f'bad-format-{i}', trap='format:', library=LIBRARY)
# Public CLI discovers Standard.Format and its transitive dependencies automatically.
p = run([ROOT / 'tools/warm', 'run', ROOT / 'warmc/language-tests/Stage6.warm'], 'public-run')
assert (p.returncode, p.stdout, p.stderr) == (0, b'STAGE 6 PASS\n', b''), (p.stdout, p.stderr)
checks.append('public-run')
(OUT / 'results.json').write_text(json.dumps(dict(passed=checks, signed_results=len(expected)), indent=2))
print(f'Language: {len(checks)} checks, {len(expected)} signed arithmetic results PASS')
