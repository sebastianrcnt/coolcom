#!/usr/bin/env python3
"""Package original builtin source as data; never generate compiler logic."""
from pathlib import Path
import json
root = Path(__file__).resolve().parents[2]
out = root / 'build/warmcool/Builtins.HC'
with out.open('w') as f:
    f.write('// Generated from lib/builtin; Apache-2.0 WITH LLVM-exception.\n')
    f.write('U0 WBuiltins(CWUnit *u) {\n')
    for name in ('Pervasive.aui', 'Pervasive.aum', 'Memory.aui', 'Memory.aum'):
        text = (root / 'warmc/lib/builtin' / name).read_text()
        # HolyC has no adjacent string concatenation. Fill a buffer by line.
        f.write(f'  U8 *{name.replace('.', '_')}=WAlloc(u,{len(text.encode())+1});\n')
        offset = 0
        for line in text.splitlines(keepends=True):
            f.write(f'  MemCpy({name.replace('.', '_')}+{offset},{json.dumps(line)},{len(line.encode())});\n')
            offset += len(line.encode())
        f.write(f'  WParse(u,"builtin/{name}",{name.replace('.', '_')},{"TRUE" if name.endswith(".aum") else "FALSE"});\n')
    f.write('}\n')

with (root / 'build/warmcool/RuntimeText.HC').open('w') as f:
    text = (root / 'warmc/Cool/Runtime.HC').read_text()
    f.write('U8 *WRuntime(CWUnit *u) {\n')
    f.write(f'  U8 *text=WAlloc(u,{len(text.encode())+1});\n')
    offset = 0
    for line in text.splitlines(keepends=True):
        f.write(f'  MemCpy(text+{offset},{json.dumps(line)},{len(line.encode())});\n')
        offset += len(line.encode())
    f.write('  return text;\n}\n')
