#!/usr/bin/env python3
"""Short host regression tests for translated Lua, including error recovery and the REPL."""
from pathlib import Path
import os
import pty
import subprocess
ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / 'build/coolc'
BIN = ROOT / 'build/lua/Lua.BIN'
def run(*args, input=None):
    return subprocess.run([str(HOST), '--run', str(BIN), *map(str,args)],
                          cwd=ROOT, input=input, capture_output=True, timeout=15)
p = run(ROOT / 'tools/lua-support/test.lua')
assert p.returncode == 0 and p.stdout == b'LUA TEST PASS\n', (p.returncode, p.stdout, p.stderr)
p = run(input=b'print("LUA REPL "..string.upper("ok"))\nos.exit(0)\n')
assert p.returncode == 0 and b'LUA REPL OK' in p.stdout, (p.returncode, p.stdout, p.stderr)
# Closed pipe EOF, including an unfinished chunk, must finish without os.exit().
for source in [b'', b'print("PIPE EOF OK")\n', b'function unfinished()\n']:
    p = run(input=source)
    assert p.returncode == 0, (p.returncode, p.stdout, p.stderr)
    assert (b'<eof>' in p.stderr) == (b'unfinished' in source), (p.stdout, p.stderr)
    if b'PIPE EOF OK' in source:
        assert b'PIPE EOF OK' in p.stdout, p.stdout
# A real canonical terminal turns empty-line Ctrl+D into EOF on the host.
master, slave = pty.openpty()
try:
    p = subprocess.Popen([str(HOST), '--run', str(BIN)], cwd=ROOT,
                         stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.close(slave)
    slave = None
    os.write(master, b'exit\nprint("PTY EOF OK")\n\x04')
    stdout, stderr = p.communicate(timeout=15)
    assert p.returncode == 0 and b'PTY EOF OK' in stdout, (p.returncode, stdout, stderr)
    assert b'Use os.exit() or Ctrl+D' in stdout and b'\nnil\n' not in stdout, stdout
finally:
    if slave is not None:
        os.close(slave)
    os.close(master)
    if p.poll() is None:
        p.kill()
        p.wait()
# The hint is REPL-only, and must not intercept defined globals or continuations.
p = run('-i', input=b'  exit  \nexit = 42\nexit\nprint("exit")\n'
                    b'x = [[\nexit\n]]\nprint(x == "exit\\n")\n')
assert p.returncode == 0 and p.stdout.count(b'Use os.exit() or Ctrl+D') == 1, (p.stdout, p.stderr)
assert b'42\n' in p.stdout and b'true\n' in p.stdout and not p.stderr, (p.stdout, p.stderr)
p = run('-e', 'assert(exit == nil)')
assert p.returncode == 0 and not p.stdout and not p.stderr, (p.stdout, p.stderr)
p = run(ROOT / 'build/lua/missing-file.lua')
assert p.returncode != 0 and b'cannot open' in p.stderr, (p.returncode, p.stdout, p.stderr)
print('lua-test: Lua libraries, REPL exit hint, pipe/terminal EOF and file errors PASS')
