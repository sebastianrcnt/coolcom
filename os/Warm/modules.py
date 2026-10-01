"""CoolOS integration sources and their installed guest paths."""
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'warmc'))
from os_modules import os_modules as portable_modules


def os_modules(root):
    std = Path(root) / 'os/Warm/standard/src'
    names = ['OS/CoolOS/Framebuffer', 'OS/CoolOS/Key', 'OS/CoolOS/Task', 'OS/CoolOS/System']
    return portable_modules(root) + [','.join(str(p) for p in [std / (n + '.warmh'), std / (n + '.warm')] if p.exists()) for n in names]


def disk_path(source):
    source = Path(source)
    for base, prefix in [(ROOT / 'warmc/standard/src', 'C:/Warm/Standard/'),
                         (ROOT / 'os/Warm/standard/src', 'C:/Warm/Standard/'),
                         (ROOT / 'warmc/examples', 'C:/Warm/Examples/')]:
        if source.is_relative_to(base):
            return prefix + source.relative_to(base).as_posix()
    raise ValueError(source)
