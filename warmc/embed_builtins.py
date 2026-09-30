#!/usr/bin/env python3
"""Package original builtin source as data; never generate compiler logic."""
from pathlib import Path
import json
root = Path(__file__).resolve().parents[1]
out = root / 'build/warmcool/Builtins.cool'
with out.open('w') as f:
    f.write('// Generated from builtin; Apache-2.0 WITH LLVM-exception.\n')
    f.write('U0 WBuiltins(CWUnit *u) {\n')
    for name in ('Pervasive.warmh', 'Pervasive.warm', 'Memory.warmh', 'Memory.warm'):
        text = (root / 'warmc/builtin' / name).read_text()
        # HolyC has no adjacent string concatenation. Fill a buffer by line.
        f.write(f'  U8 *{name.replace('.', '_')}=WAlloc(u,{len(text.encode())+1});\n')
        offset = 0
        for line in text.splitlines(keepends=True):
            f.write(f'  MemCpy({name.replace('.', '_')}+{offset},{json.dumps(line)},{len(line.encode())});\n')
            offset += len(line.encode())
        f.write(f'  WParse(u,"builtin/{name}",{name.replace('.', '_')},{"TRUE" if name.endswith(".warm") else "FALSE"});\n')
    f.write('}\n')

# WRuntime: a program's runtime; WModuleRuntime: a kernel module's (--kernel-module).
with (root / 'build/warmcool/RuntimeText.cool').open('w') as f:
    for fn, src in (('WRuntime', 'Runtime.cool'), ('WModuleRuntime', 'ModuleRuntime.cool')):
        text = (root / 'warmc' / src).read_text()
        if src == 'Runtime.cool':
            text += '\n#ifndef WARM_KERNEL\n' + ''.join((root / 'warmc' / n).read_text() for n in ['OSHost.cool', 'OSCommon.cool', 'OSDirHost.cool', 'OSNetCommon.cool', 'OSNetHost.cool', 'OSTaskHost.cool']) + '\n#endif\n'
        f.write(f'U8 *{fn}(CWUnit *u) {{\n')
        f.write(f'  U8 *text=WAlloc(u,{len(text.encode())+1});\n')
        offset = 0
        for line in text.splitlines(keepends=True):
            f.write(f'  MemCpy(text+{offset},{json.dumps(line)},{len(line.encode())});\n')
            offset += len(line.encode())
        f.write('  return text;\n}\n')
