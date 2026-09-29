#!/usr/bin/env python3
"""Adversarial semantic probes in addition to the unchanged upstream suite."""
from pathlib import Path
import importlib.util
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/warmcool/semantic-tests'
OUT.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('comparison', ROOT / 'warmc/Cool/compare.py')
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)
env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'),
           COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))


def program(decls='', body='return ExitSuccess();'):
    return f'module body Test is\n{decls}\nfunction main(): ExitCode is\n{body}\nend;\nend module body.\n'


cases = {
    'borrow-mode-from-operator': (True, program('generic [S: Region] function read(r: &![Int32,S]): Int32 is return !r; end;', 'var x: Int32 := 9; borrow r: &[Bool,R] := &!x do printLn(read(r)); end borrow; return ExitSuccess();')),
    'public-signature-interface-import': (True, {
        'A.aui': 'module A is record R: Free is x: Int32; end; end module.',
        'A.aum': 'module body A is end module body.',
        'B.aui': 'import A(R); module B is function value(r: R): Int32; end module.',
        'B.aum': 'module body B is function value(r: R): Int32 is return r.x; end; end module body.',
        'Test.aum': 'import A(R); import B(value); ' + program(body='printLn(value(R(x => 42))); return ExitSuccess();'),
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
        'A.aui': 'module A is type R: Free; function make(): R; end module.',
        'A.aum': 'module body A is record R: Free is x: Int32; end; function make(): R is return R(x => 42); end; end module body.',
        'Test.aum': 'import A(R,make); ' + program(body=body + ' return ExitSuccess();'),
    })
results = []
for name, (success, source) in cases.items():
    dest = OUT / name
    dest.mkdir(exist_ok=True)
    paths = []
    sources = source if isinstance(source, dict) else {'Test.aum': source}
    for filename, contents in sources.items():
        (dest / filename).write_text(contents)
    for filename in sources:
        if filename.endswith('.aui'):
            paths.append(str(dest / filename) + ',' + str(dest / filename.replace('.aui', '.aum')))
        elif filename.replace('.aum', '.aui') not in sources:
            paths.append(str(dest / filename))

    def run(cmd, label):
        p = subprocess.run(list(map(str, cmd)), cwd=dest, env=env, capture_output=True, timeout=20)
        (dest / (label + '.stdout')).write_bytes(p.stdout)
        (dest / (label + '.stderr')).write_bytes(p.stderr)
        return p

    opts = ['compile', *paths, '--entrypoint=Test:main', '--error-format=json']
    ref = run([ROOT / 'warmc/warmc', *opts, '--target-type=c', '--output=' + str(dest / 'ref.c')], 'ocaml')
    actual = run([ROOT / 'build/coolc', '--run', ROOT / 'build/warmcool/Warm.BIN', *opts,
                  '--target-type=hc', '--output=' + str(dest / 'out.HC')], 'cool')
    reason = None
    if bool(ref.returncode) == success:
        reason = 'oracle-unexpected-result'
    elif success:
        if actual.returncode:
            reason = 'cool-' + comparison.error_kind(actual)
        else:
            cc = run(['cc', '-fwrapv', dest / 'ref.c', '-lm', '-o', dest / 'ref'], 'cc')
            hc = run([ROOT / 'build/coolc', dest / 'out.HC', dest / 'out.BIN'], 'coolc')
            if cc.returncode or hc.returncode or b'Errs:0 ' not in hc.stdout:
                reason = 'native-build'
            else:
                rp = run([dest / 'ref'], 'ref-run')
                ap = run([ROOT / 'build/coolc', '--run', dest / 'out.BIN'], 'cool-run')
                if (rp.returncode, rp.stdout, rp.stderr) != (ap.returncode, ap.stdout, ap.stderr):
                    reason = 'runtime-mismatch'
    elif name == 'duplicate-named-argument' and b'Assertion failed' in ref.stderr:
        if actual.returncode != 1 or comparison.error_kind(actual) != 'Generic Error':
            reason = 'cool-failed-to-diagnose-oracle-crash'
    elif actual.returncode != 1 or comparison.error_kind(actual) != comparison.error_kind(ref):
        reason = 'error-kind-mismatch'
    row = dict(test=name, status='FAIL' if reason else 'PASS', reason=reason,
               oracle_kind=comparison.error_kind(ref), cool_kind=comparison.error_kind(actual))
    results.append(row)
    print(row, flush=True)
(OUT / 'results.json').write_text(json.dumps(results, indent=2))
raise SystemExit(any(r['reason'] for r in results))
