#!/usr/bin/env python3
"""Compare C and native Cool for every test with recorded program output.

Artifacts and complete diagnostics stay under build/warmhc-comparison. No
compiler-error tests are counted as runtime passes. Exit nonzero on any failure.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
WARM = ROOT / 'warmc'
SUITES = WARM / 'test-programs/suites'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filter', default='')
    parser.add_argument('--timeout', type=float, default=20)
    args = parser.parse_args()
    out = ROOT / 'build/warmhc-comparison'
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
    results = []
    cases = sorted({p.parent for pattern in ('program-stdout.txt', 'program-stderr.txt')
                    for p in SUITES.glob('*/*/' + pattern)})
    for case in cases:
        name = str(case.relative_to(SUITES))
        if args.filter not in name:
            continue
        dest = out / name
        dest.mkdir(parents=True, exist_ok=True)
        stage = 'warm-c'
        row = {'test': name, 'status': 'FAIL'}

        def run(command, label, executable=None):
            proc = subprocess.run(list(map(str, command)), cwd=dest, env=env,
                                  capture_output=True, timeout=args.timeout, executable=executable)
            (dest / (label + '.stdout')).write_bytes(proc.stdout)
            (dest / (label + '.stderr')).write_bytes(proc.stderr)
            (dest / (label + '.command.json')).write_text(json.dumps(list(map(str, command))))
            return proc

        def command(target, path):
            if (case / 'cli.txt').exists():
                raw = (case / 'cli.txt').read_text().strip()
                cmd = shlex.split(raw.replace('$DIR', str(case)).replace('$C_PATH', str(path)))
                cmd[0] = str(WARM / 'warmc')
                # The old test runner runs from warmc/, including stdlib inputs.
                cmd = [str(WARM / x) if not x.startswith('-') and (WARM / x).exists()
                       else x for x in cmd]
                cmd = [x.replace('--target-type=c', '--target-type=' + target) for x in cmd]
                return cmd
            return [WARM / 'warmc', 'compile', case / 'Test.aum', '--entrypoint=Test:main',
                    '--target-type=' + target, '--output=' + str(path)]

        try:
            c = dest / 'program.c'
            hc = dest / 'program.HC'
            binary = dest / 'program.BIN'
            for stage, cmd in (
                ('warm-c', command('c', c)),
                ('cc', ['cc', '-fwrapv', c, '-lm', '-o', dest / 'program']),
                ('warm-hc', command('hc', hc)),
                ('coolc', [ROOT / 'build/coolc', hc, binary]),
            ):
                if stage == 'coolc':
                    binary.unlink(missing_ok=True)
                p = run(cmd, stage)
                if p.returncode or (stage == 'coolc' and
                                    (b'Errs:0 ' not in p.stdout or not binary.exists())):
                    message = (p.stderr + p.stdout).decode(errors='replace')
                    row['reason'] = stage
                    if 'Float32' in message:
                        row['reason'] = 'unsupported-float32'
                    elif 'HolyC backend:' in message:
                        row['reason'] = message.split('HolyC backend:', 1)[1].split('\n')[0].strip()
                    break
            else:
                stage = 'execution'
                # Give both executions the same argv[0]; no stdout normalization.
                cr = run([binary], 'c-run', executable=str(dest / 'program'))
                hr = run([ROOT / 'build/coolc', '--run', binary], 'hc-run')
                # Exact byte comparison, including stream and process exit status.
                expected = case / ('program-stderr.txt' if (case / 'program-stderr.txt').exists()
                                   else 'program-stdout.txt')
                actual = cr.stderr if expected.name == 'program-stderr.txt' else cr.stdout
                oracle = expected.read_bytes().strip()
                # This upstream fixture records its old runner's /tmp path.
                old_argv0 = '/tmp/austral_e2e_' + name.replace('/', '_') + '.bin'
                oracle = oracle.replace(old_argv0.encode(), str(binary).encode())
                if actual.strip() != oracle:
                    row['reason'] = 'c-oracle-mismatch'
                elif (cr.returncode, cr.stdout, cr.stderr) == (hr.returncode, hr.stdout, hr.stderr):
                    row['status'] = 'PASS'
                else:
                    row['reason'] = 'runtime-mismatch'
                    row['c_exit'] = cr.returncode
                    row['hc_exit'] = hr.returncode
        except subprocess.TimeoutExpired:
            row['reason'] = stage + '-timeout'
        except OSError as error:
            row['reason'] = stage + '-environment'
            row['error'] = str(error)
        results.append(row)
        print(row['status'], name, row.get('reason', ''), flush=True)
    counts = Counter(r['status'] for r in results)
    failures = Counter(r['reason'] for r in results if r['status'] != 'PASS')
    summary = {'total': len(results), 'passed': counts['PASS'], 'failed': counts['FAIL'],
               'failure_categories': dict(failures), 'results': results}
    (out / 'results.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({k: v for k, v in summary.items() if k != 'results'}, indent=2))
    return int(bool(counts['FAIL']) or not results)


if __name__ == '__main__':
    sys.exit(main())
