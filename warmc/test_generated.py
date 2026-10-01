#!/usr/bin/env python3
"""Stage 7 generated access, conservative range proofs and runtime trap regressions."""
from pathlib import Path
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/generated-tests'
OUT.mkdir(parents=True, exist_ok=True)
ENV = dict(os.environ, WARM_TOOLCHAIN_READY='1', COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
checks = []
IMPORT = 'import Standard.Buffer(Buffer, initialize, destroyFree, nth, length, storeNth, removeLast, getSpan, getSpanMut);'


def execute(label, body, decls='', expected=b'', trap=None, imports=IMPORT, unsafe=False, extra_sources=()):
    source = OUT / (label + '.warm')
    source.write_text(('pragma Unsafe_Module; ' if unsafe else '') + imports + ' module body Test is ' + decls +
                      ' function main(): ExitCode is ' + body + ' return ExitSuccess(); end; end module body.')
    extra = []
    for name, contents in extra_sources:
        path = OUT / (name + '.warm')
        path.write_text(contents)
        extra.append(path)
    code, binary = OUT / (label + '.cool'), OUT / (label + '.BIN')
    commands = [([ROOT / 'tools/warm', 'compile', str(ROOT / 'warmc/standard/src/Buffer.warmh') + ',' + str(ROOT / 'warmc/standard/src/Buffer.warm'), *extra, source, '--entrypoint=Test:main', '--output=' + str(code)], 'warm'),
                ([ROOT / 'build/coolc', code, binary], 'cool'), ([ROOT / 'build/coolc', '--run', binary], 'run')]
    for cmd, stage in commands:
        p = subprocess.run(list(map(str, cmd)), env=ENV, capture_output=True, timeout=60)
        (OUT / (label + '-' + stage + '.log')).write_bytes(p.stdout + p.stderr)
        if stage != 'run':
            assert p.returncode == 0, (label, stage, p.stdout, p.stderr)
        elif trap:
            assert p.returncode != 0 and trap.encode() in p.stderr, (label, p.returncode, p.stdout, p.stderr)
        else:
            assert p.returncode == 0 and p.stdout == expected and not p.stderr, (label, p.returncode, p.stdout, p.stderr)
    checks.append(label)
    # Runtime includes fallback helpers; inspect only emitted application functions.
    return code.read_text().split('// Warm monomorphized program')[-1]


prefix = 'var buf: Buffer[Nat64] := initialize(3, 7); var total: Nat64 := 0; '
suffix = 'printLn(total); destroyFree(buf);'
for bound in ['until length(&buf)', 'to length(&buf) - 1']:
    text = execute('buffer-' + bound.split()[0], prefix + f'for i from 0 {bound} do total := total + nth(&buf, i); end for; ' + suffix, expected=b'21\n')
    assert 'wh_abort("nth: index out of range")' not in text
text = execute('named-arguments', prefix + 'for i from 0 until length(&buf) do total := total + nth(pos => i, buf => &buf); end for; ' + suffix, expected=b'21\n')
assert 'wh_abort("nth: index out of range")' not in text
text = execute('span-until', 'read("abc");', 'function read(bytes: Span[Nat8]): Unit is for i from 0 until spanLength(bytes) do printLn(bytes[i]); end for; return nil; end;', expected=b'97\n98\n99\n')
assert ').wh_size) wh_abort("Array index out of bounds.")' not in text
text = execute('store-until', 'var b: Buffer[Nat64] := initialize(3, 0); for i from 0 until length(&b) do storeNth(&!b, i, 9); end for; printLn(nth(&b, 2)); destroyFree(b);', expected=b'9\n')
assert 'wh_abort("storeNth: index out of range")' not in text.split('U0 wf1(', 2)[2].split('\nU0 wf', 1)[0]
execute('buffer-oob', 'let b: Buffer[Nat64] := initialize(1, 0); printLn(nth(&b, 1)); destroyFree(b);', trap='nth: index out of range')
execute('store-oob', 'var b: Buffer[Nat64] := initialize(1, 0); storeNth(&!b, 1, 9); destroyFree(b);', trap='storeNth: index out of range')
execute('inclusive-length', prefix + 'for i from 0 to length(&buf) do total := total + nth(&buf, i); end for; ' + suffix, trap='nth: index out of range')
execute('other-buffer', 'let a: Buffer[Nat64] := initialize(2, 1); let b: Buffer[Nat64] := initialize(1, 1); for i from 0 until length(&a) do printLn(nth(&b, i)); end for; destroyFree(a); destroyFree(b);', trap='nth: index out of range')
execute('changed-buffer', 'var b: Buffer[Nat64] := initialize(1, 1); for i from 0 until length(&b) do let old: Nat64 := removeLast(&!b); printLn(nth(&b, i)); end for; destroyFree(b);', trap='nth: index out of range')
execute('unknown-call', 'var b: Buffer[Nat64] := initialize(1, 1); for i from 0 until length(&b) do shrink(&!b); printLn(nth(&b, i)); end for; destroyFree(b);', 'function shrink(b: &![Buffer[Nat64]]): Unit is let old: Nat64 := removeLast(&~b); return nil; end;', trap='nth: index out of range')
execute('offset-index', prefix + 'for i from 0 until length(&buf) do total := total + nth(&buf, i + 1); end for; ' + suffix, trap='nth: index out of range')
execute('cached-bound', 'var b: Buffer[Nat64] := initialize(1, 1); let n: Index := length(&b); let old: Nat64 := removeLast(&!b); for i from 0 until n do printLn(nth(&b, i)); end for; destroyFree(b);', trap='nth: index out of range')
execute('empty-inclusive-underflow', 'let b: Buffer[Nat64] := initialize(0, 1); for i from 0 to length(&b) - 1 do printLn(nth(&b, i)); end for; destroyFree(b);', trap='Overflow in trappingSubtract')
execute('empty-reversed-max', 'let b: Buffer[Nat64] := initialize(0, 1); for i from 0 until length(&b) do printLn(nth(&b, i)); end for; for j from 9 until 3 do abort("reversed"); end for; for k from 18446744073709551614 until 18446744073709551615 do printLn(k); continue; end for; for k from 18446744073709551615 to 18446744073709551615 do printLn(k); end for; destroyFree(b);', expected=b'18446744073709551614\n18446744073709551615\n')
execute('unsigned-overflow', 'let a: Nat64 := 18446744073709551615; let b: Nat64 := 1; printLn(a + b);', trap='Overflow in trappingAdd')
execute('span-oob', 'read("x");', 'function read(bytes: Span[Nat8]): Unit is for i from 0 to spanLength(bytes) do printLn(bytes[i]); end for; return nil; end;', trap='Array index out of bounds')
text = execute('span-alias', 'read("x");', 'generic [S: Region] function read(bytes: Span[Nat8,S]): Unit is for i from 0 until spanLength(bytes) do let alias: Span[Nat8,S] := bytes; printLn(alias[i]); end for; return nil; end;', expected=b'120\n')
assert ').wh_size) wh_abort("Array index out of bounds.")' in text
execute('nested-index', 'let literal: Span[Nat8, Static] := "x"; let b: Buffer[Span[Nat8,Static]] := initialize(2, literal); read(getSpan(&b, 0, 1)); destroyFree(b);', 'function read(bytes: Span[Span[Nat8,Static]]): Unit is for i from 0 until spanLength(bytes) do printLn(bytes[i][i]); end for; return nil; end;', trap='Array index out of bounds')
# A deliberately forged descriptor reaches a safe reader: its range proof must
# still preserve the independent byte-offset multiplication overflow check.
text = execute('span-multiply-overflow', 'read(forged());', 'function read(bytes: Span[Nat64]): Unit is for i from 2305843009213693952 until spanLength(bytes) do printLn(bytes[i]); end for; return nil; end;', imports='import Forge(forged);', trap='Multiplication overflow in array indexing', extra_sources=[('Forge', 'pragma Unsafe_Module; import Austral.Memory(Pointer); module body Forge is function forged(): Span[Nat64,Static] is let p: Pointer[Nat64] := @embed(Pointer[Nat64], "NULL"); return @embed(Span[Nat64,Static], "au_make_span($1, $2)", p, 2305843009213693953 : Index); end; end module body.')])
assert ').wh_size) wh_abort("Array index out of bounds.")' not in text

# A mutable Buffer loan is deliberately outside the proof's current scope.
text = execute('mutable-buffer-loan', 'var b: Buffer[Nat64] := initialize(2, 1); fill(&!b); printLn(nth(&b, 1)); destroyFree(b);', 'generic [R: Region] function fill(b: &![Buffer[Nat64], R]): Unit is for i from 0 until count(&~b) do storeNth(&~b, i, 8); end for; return nil; end; generic [R: Region] function count(b: &![Buffer[Nat64],R]): Index is return length(b : &[Buffer[Nat64],R]); end;', expected=b'8\n')
assert 'wh_abort("storeNth: index out of range")' in text
# Scope of a nested proof ends with its loop.
execute('proof-scope', 'read("x");', 'function read(bytes: Span[Nat8]): Unit is for i from 0 until spanLength(bytes) do for j from 0 until spanLength(bytes) do printLn(bytes[j]); end for; printLn(bytes[i + 1]); end for; return nil; end;', trap='Array index out of bounds')
text = execute('span-write-until', 'var b: Buffer[Nat8] := initialize(2, 0); fill(getSpanMut(&!b, 0, 1)); printLn(nth(&b, 1)); destroyFree(b);', 'function fill(bytes: Span![Nat8]): Unit is for i from 0 until spanWriteLength(bytes) do bytes[i] := 7; end for; return nil; end;', expected=b'7\n')
assert ').wh_size) wh_abort("Array index out of bounds.")' not in text
text = execute('unsafe-span', 'read("x");', 'function read(bytes: Span[Nat8]): Unit is for i from 0 until spanLength(bytes) do printLn(bytes[i]); end for; return nil; end;', expected=b'120\n', unsafe=True)
assert ').wh_size) wh_abort("Array index out of bounds.")' in text and ' == 0xffffffffffffffff) break;' in text
execute('local-accessor-names', 'for i from 0 until length(0) do printLn(nth(0, i)); end for;', 'function length(buf: Nat64): Index is return 1; end; function nth(buf: Nat64, pos: Index): Nat64 is return 99; end;', expected=b'99\n', imports='')
execute('changed-span', 'var sp: Span[Nat8,Static] := "ab"; for i from 0 until spanLength(sp) do sp := ""; printLn(sp[i]); end for;', trap='Array index out of bounds')
execute('buffer-max-index', 'let b: Buffer[Nat64] := initialize(1, 0); printLn(nth(&b, 18446744073709551615)); destroyFree(b);', trap='nth: index out of range')
execute('store-max-index', 'var b: Buffer[Nat64] := initialize(1, 0); storeNth(&!b, 18446744073709551615, 9); destroyFree(b);', trap='storeNth: index out of range')
(OUT / 'results.json').write_text(json.dumps(dict(checks=len(checks), status='PASS', cases=checks), indent=2) + '\n')
print(f'Stage 7: {len(checks)} generated-code and safety checks PASS')
