#!/usr/bin/env python3
"""Guest inputs for GUI Warm programs, sharing the OS library dependency list."""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'os/Warm'))
from modules import os_modules, disk_path
pairs = os_modules(ROOT)
if '--files' in sys.argv:
    # Files' transitive imports; avoid parsing/emitting unrelated terminal,
    # networking and CoolOS display modules on each cold app launch.
    names = {'Buffer', 'String', 'StringBuilder', 'OS/Error', 'OS/File', 'OS/Dir', 'OS/Task', 'OS/Gui'}
    base = ROOT / 'warmc/standard/src'
    pairs = [pair for pair in pairs if any((base / (name + '.warm')).as_posix() in pair for name in names)]
paths = [disk_path(p) for pair in pairs for p in pair.split(',')]
# No newline: GuiRun appends another module path.
sys.stdout.write(','.join(paths))
