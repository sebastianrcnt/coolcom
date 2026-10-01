#!/usr/bin/env python3
"""Translate Lua 5.4.9 (switch VM) with c2hc for host and OS."""
from pathlib import Path
import subprocess
import sys
import tempfile
ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'vendor/lua-5.4.9/src'
OUT = ROOT / 'build/lua'
OUT.mkdir(parents=True, exist_ok=True)
files = [str(ROOT / 'tools/lua-support/repl.c') if f.name == 'lua.c' else str(f)
         for f in sorted(SRC.glob('*.c')) if f.name != 'luac.c']
base = [sys.executable, str(ROOT / 'tools/c2hc/c2hc.py'), '--library',
        '-I', str(SRC), '-D', 'LUA_USE_JUMPTABLE=0']
# disk-files.sh can invoke another make while the top-level parallel build is
# generating Lua. Build privately and publish complete files: appending the OS
# adapter to the shared output lets two builders append LuaRun twice, and lets
# a disk copy observe an incomplete runtime.
with tempfile.TemporaryDirectory(prefix='.generate-', dir=OUT) as tmp:
    stage = Path(tmp)
    subprocess.run([*base, *files, str(stage / 'Lua.cool')], check=True)
    (stage / 'Host.cool').write_text((ROOT / 'tools/lua-support/Host.cool').read_text())
    subprocess.run([*base, '--reserved-from', str(ROOT / 'build/ShellPrelude.coolh'),
                    '--libc', 'C:/Cool/LibC/LibC.cool', *files,
                    str(stage / 'LuaRuntime.cool')], check=True)
    with (stage / 'LuaRuntime.cool').open('a') as f:
        f.write((ROOT / 'tools/lua-support/Kernel.cool').read_text())
    for name in ['Lua.cool', 'Host.cool', 'LuaRuntime.cool']:
        (stage / name).replace(OUT / name)
