#!/usr/bin/env python3
"""Check manual API coverage against the compiler and all page/example links."""
import importlib.util
import pathlib
import re
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('warm_man', pathlib.Path(__file__).with_name('warm-man.py'))
manual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manual)
ROOT = manual.ROOT


def ast(path):
    return subprocess.run([ROOT / 'tools/warm', 'compile', path, '--parse', '--dump-ast'],
                          check=True, capture_output=True, text=True).stdout


def declarations(tree):
    result = {}
    for part in re.split(r'^ declaration ', tree, flags=re.M)[1:]:
        header, _, details = part.partition('\n')
        # Function bodies are absent in interfaces; parameters, generic
        # constraints, result types, record slots and union cases must agree.
        result[header] = details.split('  body ', 1)[0].rstrip()
    return result


class WarmManTests(unittest.TestCase):
    def test_body_only_apis_match_compiler_ast(self):
        with tempfile.TemporaryDirectory() as tmp:
            for source in manual.module_sources():
                if source.suffix != '.warm':
                    continue
                with self.subTest(source=source.name):
                    text = source.read_text()
                    header = pathlib.Path(tmp) / source.with_suffix('.warmh').name
                    header.write_text(manual.body_interface(text))
                    expected = declarations(ast(source))
                    private = set(re.findall(r'\bprivate\s+(?:function|record|union|constant|type)\s+(\w+)', text))
                    expected = {key: value for key, value in expected.items()
                                if key.split()[-1] not in private}
                    self.assertEqual(expected, declarations(ast(header)))

    def test_pages_index_sources_and_examples(self):
        pages = manual.pages()
        required = {'Warm', 'WarmSyntax', 'WarmRun', 'WarmCompile', 'WarmExamples',
                    'OS.Terminal', 'OS.File', 'OS.Dir', 'OS.Net', 'OS.Task',
                    'OS.Time', 'OS.Random', 'OS.Error', 'OS.CoolOS',
                    'OS.CoolOS.Framebuffer', 'OS.CoolOS.Key', 'OS.CoolOS.Task', 'OS.CoolOS.System'}
        self.assertTrue(required <= pages.keys())
        for name, content in pages.items():
            for target in re.findall(r'Man\("([\w.]+)"\)', content):
                if target in {'Name', 'StrLen', 'CTask', 'jiffies'}:
                    continue
                self.assertIn(target, pages, f'{name} links to missing page {target}')
            if name != 'index':
                self.assertIn(f'Man("{name}")', pages['index'])
        for source in manual.module_sources():
            name = re.search(r'^module (?:body )?([\w.]+) is$', source.read_text(), re.M).group(1)
            if source.suffix == '.warmh':
                self.assertIn(source.read_text(), pages[name], name)
            else:
                self.assertNotRegex(pages[name], r'\bprivate (?:function|record|union|type|constant)\b', name)
            self.assertIn(str(source.relative_to(ROOT)), pages[name])
        for path in re.findall(r'C:/[\w/.-]+', pages['WarmExamples']):
            path = path.rstrip('.')
            if path.startswith('C:/Warm/Examples/'):
                source = ROOT / 'warmc/examples' / path.removeprefix('C:/Warm/Examples/')
            elif path == 'C:/HelloWarm.warm':
                source = ROOT / 'os/Disk/HelloWarm.warm'
            elif path == 'C:/Warm/Docs/README.md':
                source = ROOT / 'warmc/README.md'
            else:
                self.fail(f'Unmapped example path: {path}')
            self.assertTrue(source.exists(), path)
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp)
            manual.generate(output)
            self.assertEqual(set(pages), {p.stem for p in output.glob('*.txt')})


if __name__ == '__main__':
    unittest.main()
