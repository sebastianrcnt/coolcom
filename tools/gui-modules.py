#!/usr/bin/env python3
"""Guest library inputs for GUI Warm programs, sharing the OS library dependency list.

Without arguments: every OS library module (C:/GuiModules.txt, the fallback).
--app NAME: only the transitive imports of warmc/examples/gui/NAME.warm (walked
from the sources, so library changes cannot leave a module out); the kernel's
GuiRun reads them from C:/<EntryModule>Modules.txt. --files is --app Files.
The program's own files are not listed: GuiRun appends them.
"""
from pathlib import Path
import re
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'os/Warm'))
from modules import os_modules, disk_path
pairs = os_modules(ROOT)
BASES = [ROOT / 'warmc/standard/src', ROOT / 'os/Warm/standard/src']
EXAMPLES = ROOT / 'warmc/examples/gui'


def file_of(module):
    parts = module.split('.')
    rel = '/'.join(parts[1:]) if parts[0] == 'Standard' else '/'.join(parts)
    for base in BASES:
        if (base / rel).with_suffix('.warm').exists():
            return base / rel
    return EXAMPLES / rel


def closure(app):
    names, todo = set(), [EXAMPLES / (app + '.warm')]
    while todo:
        text = todo.pop().read_text()
        for module in re.findall(r'^\s*import\s+([A-Za-z][\w.]*)', text, re.M):
            stem = file_of(module)
            if stem.with_suffix('.warm').exists() and module not in names:
                names.add(module)
                todo += [q for q in (stem.with_suffix('.warmh'), stem.with_suffix('.warm')) if q.exists()]
    return {file_of(m).with_suffix('.warm').as_posix() for m in names}


if '--all' in sys.argv:
    # One process writes every list (a disk install runs this once per VM test).
    out = Path(sys.argv[sys.argv.index('--all') + 1])
    every = [disk_path(p) for pair in pairs for p in pair.split(',')]
    (out / 'GuiModules.txt').write_text(','.join(every))
    for spec in sys.argv[sys.argv.index('--all') + 2:]:
        app, entry = spec.split(':')
        wanted = closure(app)
        chosen = [pair for pair in pairs if any(w in pair.split(',') for w in wanted)]
        (out / f'{entry}Modules.txt').write_text(','.join(disk_path(p) for pair in chosen for p in pair.split(',')))
    sys.exit(0)
app = None
if '--files' in sys.argv:
    app = 'Files'
if '--app' in sys.argv:
    app = sys.argv[sys.argv.index('--app') + 1]
if app:
    wanted = closure(app)
    pairs = [pair for pair in pairs if any(w in pair.split(',') for w in wanted)]
paths = [disk_path(p) for pair in pairs for p in pair.split(',')]
# No newline: GuiRun appends another module path.
sys.stdout.write(','.join(paths))
