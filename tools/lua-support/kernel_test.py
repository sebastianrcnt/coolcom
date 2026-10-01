#!/usr/bin/env python3
"""Run translated Lua files and the REPL in the real OS shell."""
import sys
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/lua-kernel-test'
OUT.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(ROOT / 'tools'))
import testvm
def run(*args):
    p = subprocess.run(list(map(str,args)), cwd=ROOT, capture_output=True, timeout=30)
    assert p.returncode == 0, (p.stdout, p.stderr)
    return p
img = OUT / 'disk.img'
testvm.create_disk(img, capture_output=True)
for d in ['Cool','Cool/LibC']: run('mmd','-i',img,'::'+d)
for src,dest in [(ROOT/'os/Disk/Lua.cool','Lua.cool'),
                 (ROOT/'build/lua/LuaRuntime.cool','LuaRuntime.cool'),
                 (ROOT/'coolc/LibC/LibC.cool','Cool/LibC/LibC.cool'),
                 (ROOT/'tools/lua-support/test.lua','x.lua')]:
    run('mcopy','-o','-i',img,src,'::'+dest)
init = OUT/'Init.cool'
init.write_text('#include "C:/Lua.cool"\n')
run('mcopy','-o','-i',img,init,'::Init.cool')
script = OUT/'input'
script.write_text('wait Cool shell\nwait C:/> \n' + testvm.typed_line('Lua("C:/x.lua");') +
                  'wait LUA TEST PASS\nwait C:/> \n' + testvm.typed_line('Lua;') +
                  'wait Lua 5.4.9\nwait > \n' + testvm.typed_line('print("LUA REPL "..string.upper("ok"))') +
                  'wait LUA REPL OK\nwait > \n' + testvm.typed_line('os.exit(0)') + 'wait C:/> \n' +
                  testvm.typed_line('Lua("C:/x.lua");') + 'wait LUA TEST PASS\nwait C:/> \nquit\n')
log = OUT/'console.log'
proc = testvm.run_vm(testvm.vm_command(ROOT / 'build/kernel.Image', timeout=40,
    disk=img, input_script=script, host_timeout=45), log, cwd=ROOT, timeout=50)
s = log.read_text(errors='replace').split('Cool shell:', 1)[-1]
assert proc.returncode == 0, f'Lua VM exited with status {proc.returncode}:\n{s[-6000:]}'
assert s.count('LUA TEST PASS') == 2 and 'LUA REPL OK' in s and 'ERROR:' not in s and 'Free: bad pointer' not in s, s[-6000:]
print('lua-kernel-test: Lua("C:/x.lua"), Lua; REPL, pcall and repeated invocation PASS')
