#!/usr/bin/env python3
"""Build a single source file for #include in the running kernel shell."""
from pathlib import Path
import json
root = Path(__file__).resolve().parents[2]
source = root / 'warmc/Cool'
out = root / 'build/warmcool/Kernel.cool'
runtime = (source / 'Runtime.cool').read_text()
runtime = '\n'.join(line for line in runtime.splitlines()
                    if not line.startswith(('#define ', 'import '))) + '\n'
for name, adapter in [('NativeExit', 'WKernelExit'), ('NativeErrPutS', 'WKernelErrPutS'),
                      ('NativeArgCount', 'WKernelArgCount'), ('NativeArg', 'WKernelArg')]:
    runtime = runtime.replace(name, adapter)
# TempleOS Print uses its own length conventions. Preserve numeric meaning.
runtime = runtime.replace('"%zu"', '"%u"').replace('"%li"', '"%d"')
with out.open('w') as f:
    f.write('// Generated standalone kernel-shell Warm compiler. See warmc/Cool.\n')
    for line in (source / 'Warm.cool').read_text().splitlines():
        if line.startswith('#include '):
            f.write((source / line.split('"')[1]).read_text() + '\n')
    f.write((source / 'Diagnostic.cool').read_text())
    f.write((root / 'build/warmcool/Builtins.cool').read_text())
    f.write('U8 *WKernelRuntime(CWUnit *u) {\n')
    f.write(f'U8 *text=WAlloc(u,{len(runtime.encode())+1});\n')
    offset = 0
    for line in runtime.splitlines(keepends=True):
        f.write(f'MemCpy(text+{offset},{json.dumps(line)},{len(line.encode())});\n')
        offset += len(line.encode())
    f.write('return text;\n}\n')
    f.write((source / 'Kernel.cool').read_text())
print(out)
