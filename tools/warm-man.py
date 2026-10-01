#!/usr/bin/env python3
"""Generate C:/Man pages from narrative notes and current OS module interfaces.

Run into a fresh staging directory for each disk install, so parallel VM tests
never share partially written pages. No generated pages are committed.
"""
import argparse
import pathlib
import re
import sys
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
OS = ROOT / 'warmc/standard/src/OS'
NOTES = ROOT / 'docs/man'
sys.path.insert(0, str(ROOT / 'os/Warm'))
from modules import os_modules, disk_path


def body_interface(source):
    """Extract the declarations of the small, body-only OS modules.

    Warmfmt places module declarations at four spaces. Match only that level,
    omit private declarations and function bodies, and preserve type layouts.
    Tests compare their parsed declarations with warmc's AST of the real body.
    """
    module = re.search(r'^module body ([\w.]+) is$', source, re.M).group(1)
    declarations = []
    pattern = re.compile(
        r'^    (generic\s*\[.*?\]\s*)?(function\s+.*?\bis\b|'
        r'(?:record|union)\s+.*?\bend;|(?:type|constant)\s+.*?;)', re.M | re.S)
    for match in pattern.finditer(source):
        generic, declaration = match.groups()
        if declaration.startswith('function '):
            declaration = declaration[:-2].rstrip() + ';'
        declarations.append('    ' + (generic or '') + declaration)
    return f'module {module} is\n' + '\n'.join(declarations) + '\nend module.\n'


def module_sources():
    for body in sorted([*OS.rglob('*.warm'), *(ROOT / 'os/Warm/standard/src/OS').rglob('*.warm'), OS.parent / 'Format.warm']):
        header = body.with_suffix('.warmh')
        yield header if header.exists() else body


def pages():
    result = {p.stem: p.read_text() for p in sorted(NOTES.glob('Warm*.txt'))}
    result['WarmCompile'] = result['WarmRun']
    modules = []
    for source in module_sources():
        text = source.read_text()
        name = re.search(r'^module (?:body )?([\w.]+) is$', text, re.M).group(1)
        notes = (NOTES / (name + '.txt')).read_text()
        interface = text if source.suffix == '.warmh' else body_interface(text)
        relative = source.relative_to(ROOT)
        disk_source = disk_path(source)
        result[name] = (f'{name} - Warm standard library\n\n{notes.rstrip()}\n\n'
                        f'PUBLIC API (generated from {relative})\n'
                        f'Installed source: {disk_source}\n\n{interface}\n'
                        'See Man("Warm"), Man("WarmRun"), Man("OS.Error").\n')
        modules.append(name)
    result['OS.CoolOS'] = ('OS.CoolOS - platform modules\n\n' + '\n'.join(
        f'    Man("{name}");' for name in modules if name.startswith('OS.CoolOS.')) +
        '\n\nThese operations use CoolOS adapters. Unsupported host operations\n'
        'return Err(Other). See each module for its capability and ownership.\n')
    paths = []
    for group in os_modules(ROOT):
        paths.extend(disk_path(p)
                     for p in group.split(','))
    assert len(','.join(paths)) + 100 < 4096
    result['WarmModules'] = ('WarmModules - OS library inputs for WarmRun\n\n'
        'Generated from os/Warm/modules.py, the dependency list used by OS tests.\n'
        'Run these shell statements to build the full OS library input list.\n'
        'Each statement fits the shell input limit; do not join all lines.\n\n'
        '    U8 wm_paths[4096]; wm_paths[0] = 0;\n' +
        '\n'.join(f'    StrCat(wm_paths, "{p},");' for p in paths) +
        '\n\nAppend a program and invoke its module entrypoint, for example:\n'
        '    StrCat(wm_paths, "C:/Warm/Examples/kernel/Files.warm");\n'
        '    WarmRun(wm_paths, "Files:main");\n\n'
        'Rebuild wm_paths before choosing another program; the list has a trailing\n'
        'comma until a program is appended. You may omit unused modules if you\n'
        'keep all imports and their transitive dependencies. Pervasive/Memory\n'
        'are embedded and need no paths. See Man("WarmRun").\n')
    index = ['Man - manual index', '',
             'Man; or Man("index"); opens this index. :q returns to the shell.',
             'Man("Name"); opens a page in Vim; /text searches within the page.',
             'Names without a page use the existing symbol/source lookup.', '',
             'Warm language and tools:']
    for name in sorted(n for n in result if n.startswith('Warm')):
        index.append(f'    Man("{name}");')
    index += ['', 'Warm standard library modules:', '    Man("OS.CoolOS");']
    index += [f'    Man("{name}");' for name in modules]
    index += ['', 'Source help: Man("StrLen"); Man("CTask"); Man("jiffies");', '',
              'Pages: C:/Man/*.txt (generated at disk installation).',
              'Full source documents: C:/Warm/Docs/README.md, warm-stdlib.md,',
              'warm-closures.md. Examples: C:/Warm/Examples/.']
    result['index'] = '\n'.join(index) + '\n'
    return result


def generate(output):
    output.mkdir(parents=True, exist_ok=True)
    for name, content in pages().items():
        # Wrap prose only. Keep Warm declarations, imports and command lines intact.
        lines = []
        for line in content.splitlines():
            if line and not line[0].isspace() and len(line) > 78 and not line.startswith(('import ', 'module ')):
                lines.extend(textwrap.wrap(line, width=78))
            else:
                lines.append(line)
        (output / (name + '.txt')).write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    generate(parser.parse_args().output)
