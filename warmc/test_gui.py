#!/usr/bin/env python3
"""GUI authority and lifetime boundaries are checked by the Warm compiler."""
from pathlib import Path
import subprocess
from os_modules import os_modules
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/warm-gui'
OUT.mkdir(parents=True, exist_ok=True)
imports = 'import OS.Gui (Gui, Window, open, close, acquireGui, releaseGui); import OS.Error (IoError);\n'
probes = [
    ('forge-window', 'let window: Window := Window(handle => 1); close(window);', False, 'callable'),
    ('forge-gui', 'let gui: Gui := Gui(); releaseGui(gui);', False, 'callable'),
    ('missing-authority', 'open("Test", 320, 200);', False, 'Wrong number of arguments'),
    ('root-authority', 'var gui: Gui := acquireGui(&!root); case open(&!gui, "Test", 320, 200) of when Ok(value as window: Window) do close(window); when Err(error as error: IoError) do skip; end case; releaseGui(gui);', True, ''),
    ('unclosed-window', 'var gui: Gui := acquireGui(&!root); case open(&!gui, "Test", 320, 200) of when Ok(value as window: Window) do skip; when Err(error as error: IoError) do skip; end case; releaseGui(gui);', False, 'Linearity Error'),
]
for name, body, success, diagnostic in probes:
    path = OUT / (name + '.warm')
    path.write_text(imports + 'module body Probe is function main(initial: RootCapability): ExitCode is var root: RootCapability := initial; ' + body + ' surrenderRoot(root); return ExitSuccess(); end; end module body.\n')
    p = subprocess.run([ROOT / 'tools/warm', 'compile', *os_modules(ROOT), path, '--check'], capture_output=True, text=True)
    assert (p.returncode == 0) == success and diagnostic in p.stdout + p.stderr, (name,p.stdout,p.stderr)
    print('gui: ' + name + ' PASS')
# Compile all widget bodies and the example, including the host's unsupported ABI.
subprocess.run([ROOT / 'tools/warm','compile',*os_modules(ROOT),ROOT / 'warmc/examples/gui/Widgets.warm',
    '--entrypoint=Widgets:main','--output=' + str(OUT / 'Widgets.cool')],check=True)
p = subprocess.run([ROOT / 'tools/warm', 'build', OUT / 'Widgets.cool', '-o', OUT / 'Widgets.BIN'],capture_output=True,text=True)
assert p.returncode == 0, p.stdout + p.stderr
print('gui: widget host ABI PASS')
