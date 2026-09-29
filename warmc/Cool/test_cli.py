#!/usr/bin/env python3
"""Entrypoint-free output, exports and diagnostic protocol regressions."""
from pathlib import Path
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/warmcool/cli-tests'
OUT.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'),
           COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
cmd = [ROOT / 'build/coolc', '--run', ROOT / 'build/warmcool/Warm.BIN']
source = OUT / 'Library.aum'
source.write_text('''module body Library is
pragma Foreign_Export(External_Name => "exported_increment");
function increment(x: Int32): Int32 is return x + 1; end;
function main(): ExitCode is printLn("ENTRYPOINT SHOULD NOT RUN"); return ExitSuccess(); end;
end module body.
''')
checks = []

def run(command, label):
    p = subprocess.run(list(map(str, command)), cwd=OUT, env=env, capture_output=True, timeout=20)
    (OUT / (label + '.stdout')).write_bytes(p.stdout)
    (OUT / (label + '.stderr')).write_bytes(p.stderr)
    return p

out = OUT / 'Library.HC'
p = run([*cmd, 'compile', source, '--no-entrypoint', '--target-type=hc', '--output=' + str(out)], 'library')
assert p.returncode == 0, p.stdout + p.stderr
text = out.read_text()
assert 'WarmMain' not in text and 'extern I32 exported_increment(' in text
out.write_text(text + '\nPrint("%d\\n",exported_increment(19));\n')
p = run([ROOT / 'build/coolc', out, OUT / 'Library.BIN'], 'coolc')
assert p.returncode == 0 and b'Errs:0 ' in p.stdout, p.stdout + p.stderr
p = run([ROOT / 'build/coolc', '--run', OUT / 'Library.BIN'], 'execute')
assert (p.returncode, p.stdout, p.stderr) == (0, b'20\n', b''), p
checks += ['no-entrypoint', 'exported-call']
bad = OUT / 'Bad.aum'
bad.write_text('module body Broken is\nfunction main(): ExitCode is\nreturn ;\nend;\nend module body.\n')
p = run([*cmd, '--parse', bad, '--error-format=json'], 'json')
error = json.loads(p.stderr)
assert p.returncode == 1 and error['kind'] == 'Parse Error'
assert error['span']['filename'] == str(bad) and error['span']['startp']['line'] == 3
p = run([*cmd, '--parse', bad], 'caret')
assert p.returncode == 1 and b'Bad.aum:3:' in p.stdout and b'\nreturn ;\n       ^\n' in p.stdout, p.stdout
checks += ['json-location', 'plain-caret']
p = run([*cmd, source, '--target-type=invalid', '--error-format=json'], 'invalid-option')
assert p.returncode == 1 and b'Command Line Arguments Error' in p.stdout + p.stderr
checks += ['invalid-option']
(OUT / 'results.json').write_text(json.dumps(dict(passed=checks), indent=2))
print('PASS', ', '.join(checks))
