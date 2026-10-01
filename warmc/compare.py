#!/usr/bin/env python3
"""Run the test-programs suites against their stored expectations.

Every case under warmc/test-programs/suites is compiled by the Warm compiler in Cool
(build/warmcool/Warm.BIN, run by coolc). A case with austral-stderr.txt must fail with
that error kind. Any other case must compile to Cool, build with coolc and run; its stdout
must equal program-stdout.txt (empty when the file is missing) and it must exit nonzero
exactly when program-stderr.txt exists, with that stderr. cli.txt gives custom arguments.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
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


def arguments(case, output):
    cli = case / 'cli.txt'
    if cli.exists():
        raw = cli.read_text().replace('$DIR', str(case)).replace('$C_PATH', str(output))
        args = shlex.split(raw)[1:]
        args = [a for a in args if not a.startswith(('--target-type=', '--error-format='))]
        args += ['--target-type=hc', '--error-format=json']
        return args
    return ['compile', str(case / 'Test.warm'), '--entrypoint=Test:main',
            '--target-type=hc', '--output=' + str(output), '--error-format=json']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filter', default='')
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--parse-only', action='store_true')
    parser.add_argument('--jobs', type=int, default=os.cpu_count() or 4)
    args = parser.parse_args()
    out = ROOT / 'build/warmcool-comparison'
    if args.parse_only:
        out = ROOT / 'build/warmcool-parse'
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'),
               COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
    (ROOT / 'build/tmp').mkdir(parents=True, exist_ok=True)
    cool = [ROOT / 'tools/warm', 'compile']
    cases = [p for p in sorted(SUITES.glob('*/*')) if p.is_dir() and args.filter in str(p.relative_to(SUITES))]

    def check(case):
        name = str(case.relative_to(SUITES))
        dest = out / name
        dest.mkdir(parents=True, exist_ok=True)
        row = {'test': name, 'status': 'FAIL'}
        stage = 'setup'

        def run(cmd, label):
            nonlocal stage
            stage = label
            cmd = list(map(str, cmd))
            (dest / (label + '.command.json')).write_text(json.dumps(cmd))
            p = subprocess.run(cmd, cwd=WARM, env=env, capture_output=True, timeout=args.timeout)
            (dest / (label + '.stdout')).write_bytes(p.stdout)
            (dest / (label + '.stderr')).write_bytes(p.stderr)
            (dest / (label + '.exit')).write_text(str(p.returncode))
            return p

        try:
            if args.parse_only:
                sources = sorted(case.glob('*.warm*'))
                if not sources:
                    row['reason'] = 'no-sources'
                else:
                    p = run([*cool, '--parse', *sources], 'cool-parse')
                    if p.returncode == 0:
                        row['status'] = 'PASS'
                    else:
                        row['reason'] = error_kind(p)
                return row
            hc = dest / 'program.cool'
            binary = dest / 'program.BIN'
            for f in (hc, binary):
                f.unlink(missing_ok=True)
            actual = run([*cool, *arguments(case, hc)], 'cool')
            expectation = case / 'austral-stderr.txt'
            if expectation.exists():
                expected_kind = json.loads(expectation.read_text())['kind']
                row.update(expected_kind=expected_kind, cool_kind=error_kind(actual))
                if actual.returncode != 1 or error_kind(actual) != expected_kind:
                    row['reason'] = 'error-kind-mismatch'
                else:
                    row['status'] = 'PASS'
            elif actual.returncode or not hc.exists():
                row['reason'] = error_kind(actual) if actual.returncode else 'missing-output'
            else:
                build = run([ROOT / 'tools/warm', 'build', hc, '-o', binary], 'coolc')
                if build.returncode or not binary.exists():
                    row['reason'] = 'cool-native-build'
                else:
                    ap = run([ROOT / 'tools/warm', 'run', binary], 'cool-run')
                    stdout = case / 'program-stdout.txt'
                    stderr = case / 'program-stderr.txt'
                    # The stderr fixtures name the binary by the path the original suite used.
                    old_path = '/tmp/austral_e2e_' + name.replace('/', '_') + '.bin'

                    def fixture(path):
                        return path.read_bytes().strip().replace(old_path.encode(), str(binary).encode()) if path.exists() else b''
                    if (ap.stdout.strip(), ap.stderr.strip()) != (fixture(stdout), fixture(stderr)):
                        row['reason'] = 'output-mismatch'
                    elif bool(ap.returncode) != stderr.exists():
                        row['reason'] = 'exit-status-mismatch'
                    else:
                        row['status'] = 'PASS'
        except subprocess.TimeoutExpired:
            row['reason'] = stage + '-timeout'
        except (OSError, ValueError) as e:
            row.update(reason=stage + '-environment', detail=str(e))
        return row

    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for row in pool.map(check, cases):
            results.append(row)
            print(row['status'], row['test'], row.get('reason', ''), flush=True)
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
