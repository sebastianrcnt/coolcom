#!/usr/bin/env python3
"""Bit-exact IEEE binary32 conversion checks against Python's platform IEEE pack."""
from pathlib import Path
import json
import math
import os
import random
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/numbers'
OUT.mkdir(parents=True, exist_ok=True)
rng = random.Random(20260930)
values = [0.0, -0.0, math.inf, -math.inf, 1.0, -1.0, 1.0000000596046448,
          1.000000059604645, 16777217.0, 2.0**-150, 2.0**-149, 2.0**-126,
          (2.0 - 2.0**-23) * 2.0**127, 2.0**128]
values += [math.ldexp(rng.uniform(-2, 2), rng.randrange(-160, 140)) for _ in range(512)]
bits32 = [0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x00800000, 0x7f7fffff,
          0x7f800000, 0xff800000] + [rng.randrange(2**32) for _ in range(512)]
# Exclude NaNs: payload canonicalization is intentionally not specified here.
bits32 = [x for x in bits32 if (x & 0x7f800000) != 0x7f800000 or not (x & 0x7fffff)]
source = [f'#include "{ROOT}/coolc/LibC/LibC.cool"', f'#include "{ROOT}/warmc/Runtime.cool"', '#define Bool I8i',
          '#define TRUE 1', '#define FALSE 0', '#define NULL 0',
          'import I64 StrCmp(U8 *a,U8 *b);', f'#include "{ROOT}/warmc/Core.cool"', f'#include "{ROOT}/warmc/Fold.cool"',
          'U0 NumberTest() {', 'F64 widened;', 'CWUnit *u=WNew();']
expected = []
for x in values:
    bits = struct.unpack('<Q', struct.pack('<d', x))[0]
    try:
        wanted = struct.unpack('<I', struct.pack('<f', x))[0]
    except OverflowError:
        wanted = 0x7f800000 | (0x80000000 if x < 0 else 0)
    source.append(f'Print("%x\\n",wc_f64_to_f32(0x{bits:016x}(F64)));')
    expected.append(wanted)
for x in bits32:
    wanted = struct.unpack('<Q', struct.pack('<d', struct.unpack('<f', struct.pack('<I', x))[0]))[0]
    source.append(f'widened=wc_f32_to_f64(0x{x:08x}); Print("%lx\\n",widened(U64));')
    expected.append(wanted)
decimal_inputs = ['10000000000000000000.0', '0.1', '5e-324', '2.2250738585072014e-308',
                  '1.7976931348623157e308', '1e309', '-1e-400', '-0.0']
decimal_inputs += [repr(x) for x in values if math.isfinite(x)]
for text in decimal_inputs:
    wanted = struct.unpack('<Q', struct.pack('<d', float(text)))[0]
    source.append(f'Print("%lx\\n",WBFloatBits(u,"{text}"));')
    expected.append(wanted)
source += ['WDestroy(u);', '}', 'NumberTest();']
path = OUT / 'Test.cool'
path.write_text('\n'.join(source) + '\n')
env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'),
           COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
p = subprocess.run([ROOT / 'build/coolc', path, OUT / 'Test.BIN'], env=env,
                   capture_output=True, timeout=20)
(OUT / 'build.log').write_bytes(p.stdout + p.stderr)
assert p.returncode == 0 and b'Errs:0 ' in p.stdout, p.stdout + p.stderr
p = subprocess.run([ROOT / 'build/coolc', '--run', OUT / 'Test.BIN'], env=env,
                   capture_output=True, timeout=20)
(OUT / 'run.log').write_bytes(p.stdout + p.stderr)
actual = [int(x, 16) for x in p.stdout.splitlines()]
failures = [(i, hex(a), hex(b)) for i, (a, b) in enumerate(zip(actual, expected)) if a != b]
report = dict(total=len(expected), actual=len(actual), failures=failures, exit=p.returncode)
(OUT / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
raise SystemExit(bool(failures) or len(actual) != len(expected) or p.returncode != 0)
