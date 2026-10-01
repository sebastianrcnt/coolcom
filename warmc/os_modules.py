"""Ordered sources for the portable OS library and CoolOS extensions."""
from pathlib import Path
def os_modules(root):
    std = Path(root) / 'warmc/standard/src'
    names = ['Buffer', 'String', 'StringBuilder', 'OS/Error', 'OS/Terminal', 'OS/File', 'OS/Dir', 'OS/Net', 'OS/Task', 'OS/Time', 'OS/Random',
             'OS/CoolOS/Framebuffer', 'OS/CoolOS/Key', 'OS/CoolOS/Task', 'OS/CoolOS/System']
    return [','.join(str(p) for p in [std / (n + '.warmh'), std / (n + '.warm')] if p.exists()) for n in names]
