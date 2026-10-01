"""Ordered sources for the portable OS library (no CoolOS integration)."""
from pathlib import Path
def os_modules(root):
    std = Path(root) / 'warmc/standard/src'
    names = ['Buffer', 'Vector', 'String', 'Eq', 'Ord', 'Hash', 'HashMap', 'HashSet', 'Algorithms', 'StringBuilder', 'Format', 'OS/Error', 'OS/Terminal', 'OS/File', 'OS/Dir', 'OS/Net', 'OS/Task', 'OS/Time', 'OS/Random', 'OS/Gui', 'OS/Ui/Text', 'OS/Ui/Tree', 'OS/Ui/Engine', 'OS/Ui/Draw', 'OS/Ui', 'OS/Ui/Files']
    return [','.join(str(p) for p in [std / (n + '.warmh'), std / (n + '.warm')] if p.exists()) for n in names]
