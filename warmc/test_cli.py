#!/usr/bin/env python3
"""Entrypoint-free output, exports and diagnostic protocol regressions."""
from pathlib import Path
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warmcool/cli-tests'
OUT.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, TMPDIR=str(ROOT / 'build/tmp'),
           COOLC_COMPILER_BIN=str(ROOT / 'coolc/seed/Compiler.BIN'))
cmd = [ROOT / 'build/coolc', '--run', ROOT / 'build/warmcool/Warm.BIN']
source = OUT / 'Library.warm'
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

out = OUT / 'Library.cool'
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
# A span parameter is a pointer and a length on the Cool side, an Export_Layout record a Cool
# class with the record's field names; a negative length aborts.
source2 = OUT / 'Spans.warm'
source2.write_text('''module body Spans is
pragma Export_Layout(Name => "CStats");
record Stats: Free is count: Nat64; total: Nat64; last: Nat8; end;
pragma Foreign_Export(External_Name => "SpanStats");
function stats(bytes: Span[Nat8]): Stats is
    var t: Nat64 := 0;
    var last: Nat8 := 0;
    for i from 0 to spanLength(bytes) - 1 do t := t + widenToNat64(bytes[i]); last := bytes[i]; end for;
    return Stats(count => widenToNat64(spanLength(bytes)), total => t, last => last);
end;
end module body.
''')
out = OUT / 'Spans.cool'
p = run([*cmd, 'compile', source2, '--no-entrypoint', '--target-type=hc', '--output=' + str(out)], 'spans')
assert p.returncode == 0, p.stdout + p.stderr
text = out.read_text()
assert 'class CStats {' in text and 'U64 count;' in text and 'extern U0 SpanStats(CStats *wr, U8 *' in text, text
out.write_text(text + '\nCStats st;\nSpanStats(&st, "abc", 3);\nPrint("%d %d %d\\n", st.count, st.total, st.last);\n'
               'SpanStats(&st, "abc", -1);\n')
p = run([ROOT / 'build/coolc', out, OUT / 'Spans.BIN'], 'spans-coolc')
assert p.returncode == 0 and b'Errs:0 ' in p.stdout, p.stdout + p.stderr
p = run([ROOT / 'build/coolc', '--run', OUT / 'Spans.BIN'], 'spans-execute')
assert p.stdout == b'3 294 99\n' and b'Negative span length.' in p.stderr and p.returncode, p
checks += ['span-export', 'export-layout']
bad = OUT / 'Bad.warm'
bad.write_text('module body Broken is\nfunction main(): ExitCode is\nreturn ;\nend;\nend module body.\n')
p = run([*cmd, '--parse', bad, '--error-format=json'], 'json')
error = json.loads(p.stderr)
assert p.returncode == 1 and error['kind'] == 'Parse Error'
assert error['span']['filename'] == str(bad) and error['span']['startp']['line'] == 3
p = run([*cmd, '--parse', bad], 'caret')
assert p.returncode == 1 and b'Bad.warm:3:' in p.stdout and b'\nreturn ;\n       ^\n' in p.stdout, p.stdout
checks += ['json-location', 'plain-caret']
p = run([*cmd, source, '--target-type=invalid', '--error-format=json'], 'invalid-option')
assert p.returncode == 1 and b'Command Line Arguments Error' in p.stdout + p.stderr
checks += ['invalid-option']
(OUT / 'results.json').write_text(json.dumps(dict(passed=checks), indent=2))
print('PASS', ', '.join(checks))
