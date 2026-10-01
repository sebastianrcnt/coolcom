#!/usr/bin/env python3
"""Execute general-purpose suites and reject invalid ownership/API use."""
from pathlib import Path
import json
import os
import subprocess
from stdlib_modules import library_modules, test_modules

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/stdlib'
OUT.mkdir(parents=True, exist_ok=True)
ENV = dict(os.environ, WARM_TOOLCHAIN_READY='1')
MODULES = library_modules(ROOT)


def run(*args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], cwd=OUT, env=ENV,
                            capture_output=True, timeout=60, **kwargs)
    return result


def compile_program(path, *, check=False):
    return run(ROOT / 'tools/warm', 'compile', *MODULES, path,
               '--entrypoint=Test:main',
               *(['--check'] if check else ['--output=' + str(path.with_suffix('.cool'))]))


code = OUT / 'General.cool'
binary = OUT / 'General.BIN'
p = run(ROOT / 'tools/warm', 'compile', *MODULES, *test_modules(ROOT),
        '--entrypoint=Standard.Test.General:main', '--output=' + str(code))
assert p.returncode == 0, (p.stdout, p.stderr)
p = run(ROOT / 'tools/warm', 'build', code, '-o', binary)
assert p.returncode == 0, (p.stdout, p.stderr)
p = run(ROOT / 'tools/warm', 'run', binary)
assert p.returncode == 0, (p.stdout, p.stderr)
expected = ('STDLIB EQ HASH ORD PASS\nSTDLIB VECTOR PASS\nSTDLIB HASHMAP PASS\n'
            'STDLIB HASHSET PASS\nSTDLIB ALGORITHMS PASS\n'
            'STDLIB TEXT UTF8 PARSE FORMAT PASS\nWARM STDLIB PASS\n').encode()
assert p.stdout == expected, p.stdout
(OUT / 'General.stdout').write_bytes(p.stdout)

imports = '''import Standard.Vector (Vector, make, push, get, slice, destroyFree, destroyEmpty);
import Standard.String (String, fromLiteral, destroyString);
import Standard.Eq (Eq);
import Standard.Hash (Hash);
import Standard.HashMap (HashMap, make as mapMake, insert, destroyFree as mapDestroy);
'''
rejects = {
    'VectorLeak': ('let v: Vector[Index] := make();', 'not consumed'),
    'DoubleDestroy': ('let v: Vector[Index] := make(); destroyFree(v); destroyFree(v);', 'consumed'),
    'LinearCopy': ('var v: Vector[String] := make(); push(&!v, fromLiteral("x")); let x: String := get(&v, 0); destroyString(x); destroyEmpty(v);', 'Type Error'),
    'DropLinearValues': ('var v: Vector[String] := make(); push(&!v, fromLiteral("x")); destroyFree(v);', 'Free'),
    'LinearKey': ('let m: HashMap[String, Index] := mapMake(); mapDestroy(m);', 'wrong universe'),
    'LinearPrevious': ('var m: HashMap[Index, String] := mapMake(); let previous: Option[String] := insert(&!m, 1, fromLiteral("x"));', 'not consumed'),
    'BorrowAcrossGrowth': ('''var v: Vector[Index] := make(); push(&!v, 1);
        borrow read: &[Vector[Index], R] := &v do
            let view: Span[Index, R] := slice(read, 0, 1); push(&!v, 2);
            let x: Index := view[0];
        end borrow; destroyFree(v);''', 'Conflicting borrow'),
}
for name, (body, diagnostic) in rejects.items():
    source = OUT / (name + '.warm')
    source.write_text(imports + 'module body Test is\n    function main(): ExitCode is\n' +
                      body + '\nreturn ExitSuccess();\nend;\nend module body.\n')
    p = compile_program(source, check=True)
    errors = (p.stdout + p.stderr).decode()
    assert p.returncode and diagnostic in errors, (name, errors)
    (OUT / (name + '.log')).write_text(errors)

aborts = {
    'GetBounds': ('var v: Vector[Index] := make(); let x: Index := get(&v, 0); destroyFree(v);', 'index out of range'),
    'InsertBounds': ('var v: Vector[Index] := make(); StandardInsert(&!v, 1, 2); destroyFree(v);', 'index out of range'),
    'SliceBounds': ('var v: Vector[Index] := make(); let view: Span[Index, Static] := "";', ''),
    'DestroyNonempty': ('var v: Vector[Index] := make(); push(&!v, 1); destroyEmpty(v);', 'non-empty'),
}
# Invalid spans use a borrow block to name their region.
aborts['SliceBounds'] = ('''var v: Vector[Index] := make();
    borrow read: &[Vector[Index], R] := &v do
        let view: Span[Index, R] := slice(read, 1, 0);
    end borrow; destroyFree(v);''', 'invalid half-open bounds')
for name, (body, diagnostic) in aborts.items():
    source = OUT / (name + '.warm')
    source.write_text(imports.replace('Vector, make', 'insert as StandardInsert, Vector, make') +
                      'module body Test is\nfunction main(): ExitCode is\n' + body +
                      '\nreturn ExitSuccess();\nend;\nend module body.\n')
    p = compile_program(source)
    assert p.returncode == 0, (name, p.stdout, p.stderr)
    binary = source.with_suffix('.BIN')
    p = run(ROOT / 'tools/warm', 'build', source.with_suffix('.cool'), '-o', binary)
    assert p.returncode == 0, (name, p.stdout, p.stderr)
    p = run(ROOT / 'tools/warm', 'run', binary)
    output = (p.stdout + p.stderr).decode()
    assert p.returncode and diagnostic in output, (name, output)
    (OUT / (name + '.log')).write_text(output)
report = dict(suites=6, ownership_rejections=len(rejects), checked_aborts=len(aborts), result='PASS')
(OUT / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print('stdlib: ' + json.dumps(report))
