"""Pure general-purpose library and executable per-module test sources."""
from pathlib import Path

LIBRARY = ('Buffer', 'Vector', 'String', 'Eq', 'Ord', 'Hash', 'HashMap',
           'HashSet', 'Algorithms', 'StringBuilder', 'Format')
TESTS = ('GeneralSupport', 'Eq', 'Vector', 'HashMap', 'HashSet', 'Algorithms',
         'Text', 'General')


def library_modules(root):
    src = Path(root) / 'warmc/standard/src'
    return [f'{src / (name + ".warmh")},{src / (name + ".warm")}'
            for name in LIBRARY]


def test_modules(root):
    return [str(Path(root) / 'warmc/standard/test' / (name + '.warm'))
            for name in TESTS]
