#!/usr/bin/env python3
"""Adversarial semantic probes in addition to the unchanged upstream suite."""
from pathlib import Path
import importlib.util
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/semantic-tests'
OUT.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('comparison', ROOT / 'warmc/compare.py')
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)
env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'),
           COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))


def program(decls='', body='return ExitSuccess();'):
    return f'module body Test is\n{decls}\nfunction main(): ExitCode is\n{body}\nend;\nend module body.\n'


cases = {
    'borrow-mode-from-operator': (True, program('generic [S: Region] function read(r: &![Int32,S]): Int32 is return !r; end;', 'var x: Int32 := 9; borrow r: &[Bool,R] := &!x do printLn(read(r)); end borrow; return ExitSuccess();')),
    'public-signature-interface-import': (True, {
        'A.warmh': 'module A is record R: Free is x: Int32; end; end module.',
        'A.warm': 'module body A is end module body.',
        'B.warmh': 'import A(R); module B is function value(r: R): Int32; end module.',
        'B.warm': 'module body B is function value(r: R): Int32 is return r.x; end; end module body.',
        'Test.warm': 'import A(R); import B(value); ' + program(body='printLn(value(R(x => 42))); return ExitSuccess();'),
    }),
    'public-parameter-name-mismatch': (False, {
        'A.warmh': 'module A is function value(x: Int32): Int32; end module.',
        'A.warm': 'module body A is function value(y: Int32): Int32 is return y; end; end module body.',
        'Test.warm': program(),
    }),
    'opaque-parameter-count-mismatch': (False, {
        'A.warmh': 'module A is type R[A: Free]: Free; end module.',
        'A.warm': 'module body A is record R: Free is end; end module body.',
        'Test.warm': program(),
    }),
    'anonymous-region-escape': (False, program('function bad(): &[Int32, Static] is let x: Int32 := 10; return &x; end;')),
    'missing-record-payload': (False, program('record R: Linear is value: Int32; end;', 'let r: R := R(value => 7); let {} := r; return ExitSuccess();')),
    'missing-case-payload': (False, program('union U: Linear is case A is value: Int32; end;', 'let u: U := A(value => 7); case u of when A do skip; end case; return ExitSuccess();')),
    'extract-linear-field': (False, program('record Inner: Linear is end; record Outer: Linear is value: Inner; end;', 'let x: Outer := Outer(value => Inner()); let y: Inner := x.value; let {} := y; let {value: Inner} := x; let {} := value; return ExitSuccess();')),
    'discard-linear': (False, program('record R: Linear is end;', 'R(); return ExitSuccess();')),
    'write-read-reference': (False, program('record R: Free is x: Int32; end; generic [S: Region] function bad(ref: &[R,S]): Unit is ref->x := 3; return nil; end;')),
    'write-mutable-reference': (True, program('record R: Free is x: Int32; end; generic [S: Region] function change(ref: &![R,S]): Unit is ref->x := 3; return nil; end;', 'var r: R := R(x => 1); change(&!r); printLn(r.x); return ExitSuccess();')),
    'mutable-reference-cast': (True, program('generic [S: Region] function read(ref: &![Int32,S]): Int32 is let rr: &[Int32,S] := ref : &[Int32,S]; return !rr; end;', 'var x: Int32 := 9; printLn(read(&!x)); return ExitSuccess();')),
    'float32-rounding': (True, program(body='''let x: Float32 := 16777216.0;
        let y: Float32 := 1.0;
        let sum: Float32 := @embed(Float32, "$1 + $2", x, y);
        printLn(sum);
        printLn(1.00000006 : Float32);
        printLn(-0.0 : Float32);
        printLn(@embed(Float32, "$1 / $2", 3.0 : Float32, 2.0 : Float32));
        return ExitSuccess();''')),
    'float32-no-arithmetic-instance': (False, program(body='let x: Float32 := 1.0; let y: Float32 := 2.0; printLn(x + y); return ExitSuccess();')),
    'ordinary-arithmetic-traps': (True, program(body='let x: Int8 := 127; let y: Int8 := 1; printLn(x + y); return ExitSuccess();')),
    'unbounded-constant-fold': (True, program(body="let x: Nat64 := (18446744073709551615 + 1) - 1; let y: Int32 := (10000000000000000000000000000000000000 / 1000000000000000000000000000000000000) - 3; printLn(x); printLn(y); return ExitSuccess();")),
    'constant-fold-overflow': (False, program(body='let x: Nat8 := 255 + 1; return ExitSuccess();')),
    'unsigned-float-conversions': (True, program(body='case toFloat64(18446744073709551615 : Nat64) of when Some(value: Float64) do printLn(value); when None do abort("conversion"); end case; case toNat64(10000000000000000000.0 : Float64) of when Some(value: Nat64) do printLn(value); when None do abort("conversion"); end case; return ExitSuccess();')),
    'constant-function-call': (False, program('function f(): Int32 is return 7; end; constant k: Int32 := f();')),
    'duplicate-named-argument': (False, program('function f(x: Int32,y: Int32): Unit is return nil; end;', 'f(x => 1,x => 2); return ExitSuccess();')),
    'non-exhaustive-case': (False, program('union U: Free is case A; case B; end;', 'let u: U := A(); case u of when A do skip; end case; return ExitSuccess();')),
    'duplicate-case': (False, program('union U: Free is case A; end;', 'let u: U := A(); case u of when A do skip; when A do skip; end case; return ExitSuccess();')),
}
for operation, body in {
    'field': 'let r: R := make(); printLn(r.x);',
    'destructure': 'let {x: Int32} := make(); printLn(x);',
}.items():
    cases['opaque-' + operation] = (False, {
        'A.warmh': 'module A is type R: Free; function make(): R; end module.',
        'A.warm': 'module body A is record R: Free is x: Int32; end; function make(): R is return R(x => 42); end; end module body.',
        'Test.warm': 'import A(R,make); ' + program(body=body + ' return ExitSuccess();'),
    })
# Expected results (error kind, or the program's stdout, stderr and exit status) are stored in
# semantic-expected.json; they were recorded once from the reference implementation.
expected = json.loads((ROOT / 'warmc/semantic-expected.json').read_text())
results = []
for name, (success, source) in cases.items():
    dest = OUT / name
    dest.mkdir(exist_ok=True)
    paths = []
    sources = source if isinstance(source, dict) else {'Test.warm': source}
    for filename, contents in sources.items():
        (dest / filename).write_text(contents)
    for filename in sources:
        if filename.endswith('.warmh'):
            paths.append(str(dest / filename) + ',' + str(dest / filename.replace('.warmh', '.warm')))
        elif filename.replace('.warm', '.warmh') not in sources:
            paths.append(str(dest / filename))

    def run(cmd, label):
        p = subprocess.run(list(map(str, cmd)), cwd=dest, env=env, capture_output=True, timeout=20)
        (dest / (label + '.stdout')).write_bytes(p.stdout)
        (dest / (label + '.stderr')).write_bytes(p.stderr)
        return p

    want = expected[name]
    opts = ['compile', *paths, '--entrypoint=Test:main', '--error-format=json']
    actual = run([ROOT / 'build/coolc', '--run', ROOT / 'build/warmcool/Warm.BIN', *opts,
                  '--target-type=hc', '--output=' + str(dest / 'out.cool')], 'cool')
    reason = None
    if success:
        if actual.returncode:
            reason = 'cool-' + comparison.error_kind(actual)
        else:
            hc = run([ROOT / 'build/coolc', dest / 'out.cool', dest / 'out.BIN'], 'coolc')
            if hc.returncode or b'Errs:0 ' not in hc.stdout:
                reason = 'native-build'
            else:
                ap = run([ROOT / 'build/coolc', '--run', dest / 'out.BIN'], 'cool-run')
                if (ap.returncode, ap.stdout.decode(), ap.stderr.decode()) != (want['exit'], want['stdout'], want['stderr']):
                    reason = 'runtime-mismatch'
    elif actual.returncode != 1 or comparison.error_kind(actual) != want['kind']:
        reason = 'error-kind-mismatch'
    row = dict(test=name, status='FAIL' if reason else 'PASS', reason=reason, cool_kind=comparison.error_kind(actual))
    results.append(row)
    print(row, flush=True)
(OUT / 'results.json').write_text(json.dumps(results, indent=2))
raise SystemExit(any(r['reason'] for r in results))
