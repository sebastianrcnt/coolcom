#!/usr/bin/env python3
"""Short host regression tests for translated Lua, including error recovery and the REPL."""
from pathlib import Path
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
p = run(ROOT / 'build/lua/missing-file.lua')
assert p.returncode != 0 and b'cannot open' in p.stderr, (p.returncode, p.stdout, p.stderr)
print('lua-test: strings, tables, closures, pcall/error, string.format, io.write, REPL and file errors PASS')
