#!/usr/bin/env python3
"""Differential tests for the independent Cool compiler (never the OCaml HC renderer)."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
WARM = ROOT / 'warmc'
SUITES = WARM / 'test-programs/suites'
KINDS = ('Generic Error', 'Parse Error', 'Command Line Arguments Error', 'Type Error',
         'Linearity Error', 'Declaration Error', 'Entrypoint Definition Error',
         'Internal Error', 'Unsupported Feature')


def error_kind(p):
    text = (p.stderr + p.stdout).decode(errors='replace')
    try:
        return json.loads(p.stderr)['kind']
    except (ValueError, KeyError, TypeError):
        # Require a diagnostic header, not incidental words in a source excerpt.
        for line in text.splitlines():
            for kind in KINDS:
                if re.search(r'(?:^|: )' + re.escape(kind) + r':', line):
                    return kind
    return 'unclassified'


def arguments(case, target, output):
    cli = case / 'cli.txt'
    if cli.exists():
        raw = cli.read_text().replace('$DIR', str(case)).replace('$C_PATH', str(output))
        args = shlex.split(raw)[1:]
        args = [a for a in args if not a.startswith(('--target-type=', '--error-format='))]
        args += ['--target-type=' + target, '--error-format=json']
        return args
    return ['compile', str(case / 'Test.warm'), '--entrypoint=Test:main',
            '--target-type=' + target, '--output=' + str(output), '--error-format=json']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filter', default='')
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--parse-only', action='store_true')
    args = parser.parse_args()
    out = ROOT / 'build/warmcool-comparison'
    if args.parse_only:
        out = ROOT / 'build/warmcool-parse'
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'),
               COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
    cool = [ROOT / 'build/coolc', '--run', ROOT / 'build/warmcool/Warm.BIN']
    results = []
    cases = sorted(p for p in SUITES.glob('*/*') if p.is_dir())
    for case in cases:
        name = str(case.relative_to(SUITES))
        if args.filter not in name:
            continue
        dest = out / name
        dest.mkdir(parents=True, exist_ok=True)
        row = {'test': name, 'status': 'FAIL'}
        stage = 'setup'

        def run(cmd, label, executable=None):
            nonlocal stage
            stage = label
            cmd = list(map(str, cmd))
            (dest / (label + '.command.json')).write_text(json.dumps(cmd))
            p = subprocess.run(cmd, cwd=WARM, env=env, capture_output=True,
                               timeout=args.timeout, executable=executable)
            (dest / (label + '.stdout')).write_bytes(p.stdout)
            (dest / (label + '.stderr')).write_bytes(p.stderr)
            (dest / (label + '.exit')).write_text(str(p.returncode))
            return p

        try:
            if args.parse_only:
                sources = sorted(case.glob('*.au[im]'))
                if not sources:
                    row['reason'] = 'no-sources'
                else:
                    p = run([*cool, '--parse', *sources], 'cool-parse')
                    if p.returncode == 0:
                        row['status'] = 'PASS'
                    else:
                        row['reason'] = error_kind(p)
            else:
                c, hc = dest / 'oracle.c', dest / 'program.cool'
                binary = dest / 'program.BIN'
                for f in (c, hc, binary, dest / 'oracle'):
                    f.unlink(missing_ok=True)
                ref = run([WARM / 'warmc', *arguments(case, 'c', c)], 'ocaml')
                actual = run([*cool, *arguments(case, 'hc', hc)], 'cool')
                expectation = case / 'austral-stderr.txt'
                if expectation.exists():
                    expected_kind = json.loads(expectation.read_text())['kind']
                    row.update(expected_kind=expected_kind, oracle_kind=error_kind(ref),
                               cool_kind=error_kind(actual))
                    if ref.returncode == 0 or error_kind(ref) != expected_kind:
                        row['reason'] = 'oracle-error-mismatch'
                    elif actual.returncode != 1 or error_kind(actual) != expected_kind:
                        row['reason'] = 'error-kind-mismatch'
                    else:
                        row['status'] = 'PASS'
                elif ref.returncode:
                    row['reason'] = 'oracle-compile'
                elif actual.returncode or not hc.exists():
                    row['reason'] = error_kind(actual) if actual.returncode else 'missing-output'
                else:
                    cc = run(['cc', '-fwrapv', c, '-lm', '-o', dest / 'oracle'], 'cc')
                    build = run([ROOT / 'build/coolc', hc, binary], 'coolc')
                    if cc.returncode:
                        row['reason'] = 'oracle-native-build'
                    elif build.returncode or b'Errs:0 ' not in build.stdout or not binary.exists():
                        row['reason'] = 'cool-native-build'
                    else:
                        rp = run([binary], 'oracle-run', executable=str(dest / 'oracle'))
                        ap = run([ROOT / 'build/coolc', '--run', binary], 'cool-run')
                        stdout = case / 'program-stdout.txt'
                        stderr = case / 'program-stderr.txt'
                        old_path = '/tmp/austral_e2e_' + name.replace('/', '_') + '.bin'
                        def fixture(path):
                            return path.read_bytes().strip().replace(old_path.encode(), str(binary).encode()) if path.exists() else b''
                        if (rp.stdout.strip(), rp.stderr.strip()) != (fixture(stdout), fixture(stderr)) or bool(rp.returncode) != stderr.exists():
                            row['reason'] = 'oracle-runtime-expectation'
                        elif (rp.returncode, rp.stdout, rp.stderr) != (ap.returncode, ap.stdout, ap.stderr):
                            row['reason'] = 'runtime-mismatch'
                        else:
                            row['status'] = 'PASS'
        except subprocess.TimeoutExpired:
            row['reason'] = stage + '-timeout'
        except (OSError, ValueError) as e:
            row.update(reason=stage + '-environment', detail=str(e))
        results.append(row)
        print(row['status'], name, row.get('reason', ''), flush=True)
    counts = Counter(r['status'] for r in results)
    summary = dict(mode='syntax-only' if args.parse_only else 'compile-and-run',
                   total=len(results), passed=counts['PASS'], failed=counts['FAIL'],
                   failure_categories=dict(Counter(r['reason'] for r in results if r['status'] == 'FAIL')),
                   results=results)
    (out / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({k: v for k, v in summary.items() if k != 'results'}, indent=2))
    return int(bool(counts['FAIL']) or not results)


if __name__ == '__main__':
    raise SystemExit(main())
