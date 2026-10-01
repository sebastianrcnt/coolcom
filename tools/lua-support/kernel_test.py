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
ctrl_d = '1 29 1\n' + testvm.keys_of(32) + '1 29 0\n'
start_repl = testvm.typed_line('Lua;') + 'wait Lua 5.4.9\nwait > \n'
script.write_text(
    'wait Cool shell\nwait C:/> \n' + testvm.typed_line('Lua("C:/x.lua");') +
    'wait LUA TEST PASS\nwait C:/> \n' + start_repl +
    testvm.typed_line('exit') + 'wait Use os.exit() or Ctrl+D\nwait > \n' +
    # Ctrl+D with pending text must not terminate the interpreter.
    testvm.typed_line('print("LUA REPL "..string.upper("ok"))', enter=False) +
    ctrl_d + testvm.typed_line('') + 'wait LUA REPL OK\nwait > \n' +
    # Empty after editing is also EOF; no Enter is sent after Ctrl+D.
    testvm.typed_line('abc\b\b\b', enter=False) + ctrl_d + 'wait C:/> \n' +
    testvm.typed_line('Print("EOF STATUS %d\\n", lua_result);') +
    'wait EOF STATUS 0\nwait C:/> \n' + start_repl +
    testvm.typed_line('exit = 42') + 'wait > \n' +
    testvm.typed_line('exit') + 'wait 42\nwait > \n' +
    testvm.typed_line('print("EOF RESET ".."OK")') + 'wait EOF RESET OK\nwait > \n' +
    testvm.typed_line('os.exit(0)') + 'wait C:/> \n' + start_repl +
    testvm.typed_line('function unfinished()') + 'wait >> \n' +
    ctrl_d + 'wait <eof>\nwait C:/> \n' + start_repl +
    testvm.typed_line('x = [[') + 'wait >> \n' +
    testvm.typed_line('exit') + 'wait >> \n' +
    testvm.typed_line(']]') + 'wait > \n' +
    testvm.typed_line('print(x == "exit\\n" and "CONTINUATION ".."OK")') +
    'wait CONTINUATION OK\nwait > \n' + ctrl_d + 'wait C:/> \n' +
    testvm.typed_line('Lua("C:/x.lua");') + 'wait LUA TEST PASS\nwait C:/> \nquit\n')
log = OUT/'console.log'
proc = testvm.run_vm(testvm.vm_command(ROOT / 'build/kernel.Image', timeout=40,
    disk=img, input_script=script, host_timeout=45), log, cwd=ROOT, timeout=50)
s = log.read_text(errors='replace').split('Cool shell:', 1)[-1]
assert proc.returncode == 0, f'Lua VM exited with status {proc.returncode}:\n{s[-6000:]}'
assert s.count('LUA TEST PASS') == 2 and 'LUA REPL OK' in s and 'ERROR:' not in s and 'Free: bad pointer' not in s, s[-6000:]
assert s.count('Use os.exit() or Ctrl+D') == 1 and 'EOF STATUS 0' in s, s[-6000:]
assert 'EOF RESET OK' in s and 'CONTINUATION OK' in s and '<eof>' in s, s[-6000:]
print('lua-kernel-test: files, REPL exit hint, Ctrl+D, continuation EOF and reinvocation PASS')
