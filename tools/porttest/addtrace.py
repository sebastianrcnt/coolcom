#!/usr/bin/env python3
# Debug aid: insert BTrace("Name"); at the start of every function in the
# given port files (use on the build/portrt copy, never on the repo).
import re, sys
for f in sys.argv[1:]:
    lines = open(f, encoding='latin-1').read().split('\n')
    out = []
    i = 0
    sig = re.compile(r'^[A-Za-z_][\w \*]*?[ \*]([A-Za-z_]\w*)\(.*\)\s*(\{)?\s*(//.*)?$')
    while i < len(lines):
        l = lines[i]
        m = sig.match(l)
        if m and not l.startswith(('extern', 'import', '#')) and not l.rstrip().endswith(';'):
            name = m.group(1)
            if m.group(2):
                out.append(l); out.append(f'  BTrace("{name}");'); i += 1; continue
            if i + 1 < len(lines) and lines[i + 1].startswith('{'):
                out.append(l); out.append(lines[i + 1]); out.append(f'  BTrace("{name}");'); i += 2; continue
        out.append(l); i += 1
    open(f, 'w', encoding='latin-1').write('\n'.join(out))
