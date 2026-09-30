#!/usr/bin/env python3
"""Build a single source file for #include in the running kernel shell."""
from pathlib import Path
import json
root = Path(__file__).resolve().parents[1]
source = root / 'warmc'
out = root / 'build/warmcool/Kernel.cool'
runtime = (source / 'Runtime.cool').read_text()
# Drop the host's #define/import lines and the #ifndef WARM_KERNEL block: the kernel already has them.
lines, skip = [], False
for line in runtime.splitlines():
    if line.startswith('#ifndef WARM_KERNEL'):
        skip = True
    elif skip:
        skip = not line.startswith('#endif')
    elif not line.startswith(('#define ', 'import ')):
        lines.append(line)
runtime = '\n'.join(lines) + '\n'
runtime += ''.join((source / n).read_text() for n in ['OSKernel.cool', 'OSCommon.cool', 'OSDirKernel.cool']).replace('#define WARM_KERNEL 1', '')
for name, adapter in [('NativeExit', 'WKernelExit'), ('NativeErrPutS', 'WKernelErrPutS'),
                      ('NativeArgCount', 'WKernelArgCount'), ('NativeGetChar', 'WKernelGetChar'), ('NativeArg', 'WKernelArg')]:
    runtime = runtime.replace(name, adapter)
# TempleOS Print uses its own length conventions. Preserve numeric meaning.
runtime = runtime.replace('"%zu"', '"%u"').replace('"%li"', '"%d"')
with out.open('w') as f:
    f.write('// Generated standalone kernel-shell Warm compiler. See warmc.\n')
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
