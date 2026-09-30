#!/usr/bin/env python3
"""Run translated Lua files and the REPL in the real OS shell."""
import importlib.util
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/lua-kernel-test'
OUT.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('kv', ROOT / 'tools/kernel-verify.py')
kv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kv)
def run(*args):
    p = subprocess.run(list(map(str,args)), cwd=ROOT, capture_output=True, timeout=30)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p
img = OUT / 'disk.img'
with img.open('wb') as f: f.truncate(64*1024*1024)
run('mformat','-i',img,'-F','::')
for d in ['coolc','coolc/LibC']: run('mmd','-i',img,'::'+d)
for src,dest in [(ROOT/'os/Disk/Lua.cool','Lua.cool'),
                 (ROOT/'build/lua/LuaRuntime.cool','LuaRuntime.cool'),
                 (ROOT/'coolc/LibC/LibC.cool','coolc/LibC/LibC.cool'),
                 (ROOT/'tools/lua-support/test.lua','x.lua')]:
    run('mcopy','-o','-i',img,src,'::'+dest)
init = OUT/'Init.cool'
init.write_text('#include "C:/Lua.cool"\n')
run('mcopy','-o','-i',img,init,'::Init.cool')
script = OUT/'input'
script.write_text('wait Cool shell\nwait C:/> \n' + kv.typed('Lua("C:/x.lua");') +
                  'wait LUA TEST PASS\nwait C:/> \n' + kv.typed('Lua;') +
                  'wait Lua 5.4.9\nwait > \n' + kv.typed('print("LUA REPL "..string.upper("ok"))') +
                  'wait LUA REPL OK\nwait > \n' + kv.typed('os.exit(0)') + 'wait C:/> \n' +
                  kv.typed('Lua("C:/x.lua");') + 'wait LUA TEST PASS\nwait C:/> \nquit\n')
log = OUT/'console.log'
with log.open('wb') as f:
    proc = subprocess.run(['gtimeout','-k','2','45',str(ROOT/'build/coolvm'),'--headless',
                    '--cpus','2','--mem','1024','--timeout','40','--disk',str(img),
                    '--input-script',str(script),str(ROOT/'build/kernel.Image')],
                    cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,timeout=50)
s = log.read_text(errors='replace').split('Cool shell:', 1)[-1]
assert proc.returncode == 0, f'Lua VM exited with status {proc.returncode}:\n{s[-6000:]}'
assert s.count('LUA TEST PASS') == 2 and 'LUA REPL OK' in s and 'ERROR:' not in s and 'Free: bad pointer' not in s, s[-6000:]
print('lua-kernel-test: Lua("C:/x.lua"), Lua; REPL, pcall and repeated invocation PASS')
