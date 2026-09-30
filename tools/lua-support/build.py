#!/usr/bin/env python3
"""Translate Lua 5.4.9 (switch VM) with c2hc for host and OS."""
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'vendor/lua-5.4.9/src'
OUT = ROOT / 'build/lua'
OUT.mkdir(parents=True, exist_ok=True)
files = [str(f) for f in sorted(SRC.glob('*.c')) if f.name != 'luac.c']
base = [sys.executable, str(ROOT / 'tools/c2hc/c2hc.py'), '--library',
        '-D', 'LUA_USE_JUMPTABLE=0']
subprocess.run([*base, *files, str(OUT / 'Lua.cool')], check=True)
(OUT / 'Host.cool').write_text((ROOT / 'tools/lua-support/Host.cool').read_text())
subprocess.run([*base, '--reserved-from', str(ROOT / 'build/ShellPrelude.coolh'),
                '--libc', 'C:/coolc/LibC/LibC.cool', *files,
                str(OUT / 'LuaRuntime.cool')], check=True)
with (OUT / 'LuaRuntime.cool').open('a') as f:
    f.write((ROOT / 'tools/lua-support/Kernel.cool').read_text())
