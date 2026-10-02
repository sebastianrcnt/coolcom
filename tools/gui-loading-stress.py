#!/usr/bin/env python3
"""Repeat loading tests with four other test workloads running concurrently.

Run through codexctl locked. Foreground outputs are isolated for every run;
background workers each own a distinct existing test's artifact directory.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys
import threading
import time

from testvm import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel', type=Path)
    parser.add_argument('--runs', type=int, default=10)
    parser.add_argument('--venus', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/gui-loading-stress')
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('--runs must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    kernel = str(args.kernel.resolve())
    gpu = ['--venus'] if args.venus else []
    workloads = [
        ['tools/gui-apps-test.py', kernel, *gpu],
        ['tools/gui-present-test.py', kernel, *gpu],
        ['tools/gui-draw-test.py', kernel, *gpu],
        ['tools/warm-kernel-test.py', '--filter', 'Stdlib'],
    ]
    stop = threading.Event()
    ready = [threading.Event() for _ in workloads]
    results = []
    background = [[] for _ in workloads]

    def worker(index, command):
        iteration = 0
        while not stop.is_set():
            iteration += 1
            log = args.output / f'background-{index}-{iteration:02}.log'
            with log.open('wb') as stream:
                process = subprocess.Popen([sys.executable, *command], cwd=ROOT,
                                           stdout=stream, stderr=subprocess.STDOUT)
                ready[index].set()
                status = process.wait()
            background[index].append(dict(iteration=iteration, status=status, log=str(log)))
            if status:
                stop.set()
                raise RuntimeError(f'background worker {index} exited {status}: {log}')

    with ThreadPoolExecutor(max_workers=len(workloads)) as pool:
        futures = [pool.submit(worker, i, command) for i, command in enumerate(workloads)]
        try:
            for event in ready:
                event.wait()
            for run in range(1, args.runs + 1):
                if stop.is_set():
                    raise RuntimeError('background test failed; see background logs')
                out = args.output / f'run-{run:02}'
                log = args.output / f'run-{run:02}.log'
                started = time.monotonic()
                with log.open('wb') as stream:
                    process = subprocess.run([sys.executable, 'tools/gui-loading-test.py',
                        kernel, *gpu, '--loaded', '--output', str(out)], cwd=ROOT,
                        stdout=stream, stderr=subprocess.STDOUT)
                result = dict(run=run, status=process.returncode,
                              seconds=round(time.monotonic() - started, 2), log=str(log))
                results.append(result)
                (args.output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
                if process.returncode:
                    raise RuntimeError(f'loading run {run} exited {process.returncode}: {log}')
                print(f'gui-loading-stress: {run}/{args.runs} PASS in {result["seconds"]} s', flush=True)
                print(log.read_text(), end='', flush=True)
        finally:
            stop.set()
            for future in futures:
                future.result()
            (args.output / 'background.json').write_text(json.dumps(background, indent=2) + '\n')
    print(f'gui-loading-stress: {args.runs} consecutive runs with four parallel tests PASS', flush=True)


if __name__ == '__main__':
    main()
