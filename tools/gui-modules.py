#!/usr/bin/env python3
"""Guest inputs for GUI Warm programs, sharing the OS library dependency list."""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'warmc'))
from os_modules import os_modules
paths = ["C:/Warm/Standard/" + str(Path(p).relative_to(ROOT / 'warmc/standard/src'))
         for pair in os_modules(ROOT) for p in pair.split(',')]
# No newline: GuiRun appends another module path.
sys.stdout.write(','.join(paths))
