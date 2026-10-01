#!/usr/bin/env python3
"""The Warm formatter (warmc/Format.cool, tools/warmfmt): fixtures, idempotence, and meaning.

1. warmc/fmt-tests/NAME.in.warm formats to NAME.exp.warm, which is a fixed point.
2. Odd inputs (CRLF, no final newline, empty, a source that does not lex).
3. Every Warm file in the repository, the suites included, is copied and formatted: the run has no
   errors (the formatter checks that the tokens and the comments are unchanged), a second run changes
   nothing, and the parser reads the same tree (--dump-ast) before and after.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/fmt-tests'
FMT = [ROOT / 'tools/warm', 'fmt']
PARSE = [ROOT / 'tools/warm', 'compile']
failures = []


def fmt(*args):
    return subprocess.run([*map(str, FMT), *map(str, args)], capture_output=True, text=True, timeout=120)


def check(ok, what, detail=''):
    if not ok:
        failures.append(what + (': ' + detail if detail else ''))


shutil.rmtree(OUT, ignore_errors=True)
OUT.mkdir(parents=True)
subprocess.run(['make', '-s', '-f', 'tools/toolchain.mk', 'build/warmfmt.BIN'], cwd=ROOT, check=True)

# 1. Fixtures.
fixtures = sorted((ROOT / 'warmc/fmt-tests').glob('*.in.warm'))
check(fixtures, 'no fixtures')
for src in fixtures:
    name = src.name[:-len('.in.warm')]
    expected = src.with_name(name + '.exp.warm')
    work = OUT / (name + '.warm')
    shutil.copy(src, work)
    p = fmt(work)
    check(p.returncode == 0 and 'CHANGED' in p.stdout, name + ' should be changed', p.stdout + p.stderr)
    check(work.read_text() == expected.read_text(), name + ' differs from ' + expected.name)
    p = fmt('--check', expected)
    check(p.returncode == 0, name + ': the expected file is not a fixed point', p.stdout)

# 2. Odd inputs.
odd = OUT / 'odd'
odd.mkdir()
cases = {
    'crlf': ('module body A is\r\n\tfunction f(): Unit is\r\n-- c\r\nreturn nil;\r\nend;\r\nend module body.\r\n',
             'module body A is\n    function f(): Unit is\n        -- c\n        return nil;\n    end;\nend module body.\n'),
    'nofinal': ('module A is end module.', 'module A is end module.\n'),
    'empty': ('', ''),
    'blank': ('\n\n  \n', ''),
    'comments': ('  -- one\n\n\n\t-- two', '-- one\n\n-- two\n'),
    'quotes': ('module body A is\nconstant s: String := "a--b (";\nend module body.\n',
               'module body A is\n    constant s: String := "a--b (";\nend module body.\n'),
}
for name, (text, want) in cases.items():
    path = odd / (name + '.warm')
    path.write_bytes(text.encode())
    p = fmt(path)
    check(p.returncode == 0, 'odd ' + name + ' failed', p.stdout + p.stderr)
    check(path.read_bytes() == want.encode(), 'odd ' + name + ' gave ' + repr(path.read_bytes()))
for name, text in {'unterminated': 'module body A is\nconstant s: String := "abc;\nend module body.\n',
                   'badchar': 'module body A is\n  $ \nend module body.\n'}.items():
    path = odd / (name + '.warm')
    path.write_text(text)
    p = fmt(path)
    check(p.returncode == 2 and 'ERROR-LEX' in p.stdout, 'odd ' + name + ' should be an error', p.stdout)
    check(path.read_text() == text, 'odd ' + name + ' was modified')
p = fmt('--check', OUT / 'missing.warm')
check(p.returncode == 2, 'a missing file should be an error')

# 3. The whole corpus.
sources = sorted(p for d in ('warmc',) for p in (ROOT / d).rglob('*')
                 if p.suffix in ('.warm', '.warmh', '.aum', '.aui') and 'build' not in p.relative_to(ROOT).parts
                 and 'fmt-tests' not in p.relative_to(ROOT).parts)
copies = []
for p in sources:
    q = OUT / 'corpus' / p.relative_to(ROOT)
    q.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(p, q)
    copies.append(q)
check(len(copies) > 300, 'corpus too small: %d' % len(copies))
first = fmt(*copies)
check(first.returncode == 0 and 'ERROR' not in first.stdout and 'WARN' not in first.stdout,
      'formatting the corpus', first.stdout[-2000:] + first.stderr[-2000:])
second = fmt('--check', *copies)
check(second.returncode == 0, 'formatting is not idempotent', second.stdout[-2000:])


def tree(path):
    p = subprocess.run([*map(str, PARSE), '--dump-ast', str(path)], capture_output=True, timeout=60)
    # A rejected file: the kind of error only (its line and column move with the layout).
    kind = re.search(rb'\w+ Error', p.stderr + p.stdout)
    return p.returncode, p.stdout if not p.returncode else b'', kind.group(0) if kind else b''


def same(pair):
    original, formatted = pair
    a, b = tree(original), tree(formatted)
    return None if a == b else str(original.relative_to(ROOT))


with ThreadPoolExecutor(max_workers=8) as pool:
    for bad in pool.map(same, zip(sources, copies)):
        check(bad is None, 'the parse tree changed', bad or '')

if failures:
    print('warmfmt: %d failure(s)' % len(failures))
    for f in failures[:20]:
        print('  FAIL', f)
    sys.exit(1)
print('warmfmt: %d fixtures, %d odd inputs, %d corpus files (idempotent, same parse trees) PASS'
      % (len(fixtures), len(cases) + 2, len(copies)))
