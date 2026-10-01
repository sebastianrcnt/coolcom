#!/usr/bin/env python3
"""Guest inputs for GUI Warm programs, sharing the OS library dependency list."""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'os/Warm'))
from modules import os_modules, disk_path
pairs = os_modules(ROOT)
if '--files' in sys.argv:
    # Only Files' transitive imports (walked from the sources, so library changes cannot
    # leave a module out); skip unrelated terminal, networking and CoolOS display modules.
    import re
    base = ROOT / 'warmc/standard/src'
    def file_of(module):
        parts = module.split('.')
        rel = '/'.join(parts[1:]) if parts[0] == 'Standard' else '/'.join(parts)
        return base / rel
    names, todo = set(), [ROOT / 'warmc/examples/gui/Files.warm', ROOT / 'warmc/examples/gui/Support.warmh',
                          ROOT / 'warmc/examples/gui/Support.warm']
    while todo:
        text = todo.pop().read_text()
        for module in re.findall(r'^\s*import\s+([A-Za-z][\w.]*)', text, re.M):
            stem = file_of(module)
            if stem.with_suffix('.warm').exists() and module not in names:
                names.add(module)
                todo += [q for q in (stem.with_suffix('.warmh'), stem.with_suffix('.warm')) if q.exists()]
    wanted = {file_of(m).with_suffix('.warm').as_posix() for m in names}
    pairs = [pair for pair in pairs if any(w in pair.split(',') for w in wanted)]
paths = [disk_path(p) for pair in pairs for p in pair.split(',')]
# No newline: GuiRun appends another module path.
sys.stdout.write(','.join(paths))
