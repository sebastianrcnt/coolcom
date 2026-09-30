#!/usr/bin/env python3
"""Boot coolvm and compile/run Warm source inside the actual kernel shell."""
from pathlib import Path
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/kernel-test'
OUT.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'))

def run(cmd, **kwargs):
    return subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env, check=True, **kwargs)

run(['python3', ROOT / 'warmc/package_kernel.py'])
disk = OUT / 'disk.img'
with disk.open('wb') as f:
    f.truncate(64 * 1024 * 1024)
run(['mformat', '-i', disk, '-F', '-v', 'WARMC', '::'], capture_output=True)
(OUT / 'Bad.warm').write_text('module body Broken is function f(): Unit is return ; end; end module body.\n')
(OUT / 'Abort.warm').write_text('module body Test is function main(): ExitCode is abort("kernel abort probe"); end; end module body.\n')
(OUT / 'Init.cool').write_text('''#include "C:/Warm.cool"
Print("WARM-KERNEL-LOADED\\n");
Print("WARM-ABORT:%d\\n",WarmRun("C:/Abort.warm"));
Print("WARM-FIRST:%d\\n",WarmRun("C:/Test.warm"));
Print("WARM-BAD:%d\\n",WarmRun("C:/Bad.warm"));
Print("WARM-SECOND:%d\\n",WarmRun("C:/Test.warm"));
Print("WARM-KERNEL-DONE\\n");
Shutdown();
''')
files = [(ROOT / 'build/warmcool/Kernel.cool', 'Warm.cool'),
         (ROOT / 'warmc/test-programs/suites/018-hc-backend/002-record-flow-float/Test.warm', 'Test.warm'),
         (OUT / 'Abort.warm', 'Abort.warm'), (OUT / 'Bad.warm', 'Bad.warm'), (OUT / 'Init.cool', 'Init.cool')]
for src, name in files:
    run(['mcopy', '-o', '-i', disk, src, '::' + name], capture_output=True)
cmd = [ROOT / 'build/coolvm', '--headless', '--cpus', '2', '--mem', '1024', '--timeout', '35',
       '--width', '640', '--height', '480', '--disk', disk, ROOT / 'build/kernel.Image']
(OUT / 'command.json').write_text(json.dumps(list(map(str, cmd))))
with (OUT / 'log.txt').open('wb') as log:
    proc = subprocess.run(list(map(str, cmd)), cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                          stdout=log, stderr=subprocess.STDOUT, timeout=45)
text = (OUT / 'log.txt').read_text(errors='replace').replace('\r', '')
required = ['WARM-KERNEL-LOADED', 'WARM-ABORT:0', 'kernel abort probe', 'WARM-FIRST:1', 'WARM-BAD:0', 'Parse Error:',
            'WARM-SECOND:1', 'WARM-KERNEL-DONE']
missing = [x for x in required if x not in text]
# The selected fixture exercises generic calls, aggregate function pointers,
# Float64, unions, and short circuit evaluation, twice in the same shell.
expected = (ROOT / 'warmc/test-programs/suites/018-hc-backend/002-record-flow-float/program-stdout.txt').read_text().strip()
if text.count(expected) != 2:
    missing.append('two exact program outputs')
report = dict(exit=proc.returncode, missing=missing, log=str(OUT / 'log.txt'))
(OUT / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
if missing or proc.returncode:
    print(text[-16000:])
    raise SystemExit(1)
