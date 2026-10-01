#!/usr/bin/env python3
"""Exercise the public host command from projects outside the repository."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WARM = ROOT / 'tools/warm'


class HostCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='warm-project-')
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name) / 'a project'
        self.project.mkdir()

    def write(self, name, text):
        path = self.project / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def warm(self, *args, success=True):
        p = subprocess.run([str(WARM), *map(str, args)], cwd=self.project,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode == 0, success, p.stdout + p.stderr)
        return p

    def hello(self):
        return self.write('Hello.warm', '''module body Hello is
function main(): ExitCode is printLn("Hello, Warm!"); return ExitSuccess(); end;
end module body.
''')

    def test_run_build_and_arguments_outside_repo(self):
        source = self.hello()
        self.assertEqual(self.warm('run', source).stdout, 'Hello, Warm!\n')
        self.assertIn('usage:', self.warm('run', '--help').stdout)
        self.assertIn('PASS ', self.warm('test', source).stdout)
        self.warm('build', source, '-o', 'hello world')
        executable = self.project / 'hello world'
        self.assertTrue(os.access(executable, os.X_OK))
        # A copied artifact runs with no loader, source tree or compiler on PATH.
        with tempfile.TemporaryDirectory() as elsewhere:
            copy = Path(elsewhere) / 'hello'
            shutil.copy(executable, copy)
            p = subprocess.run([copy], cwd=elsewhere, env={'PATH': '/usr/bin:/bin'}, capture_output=True, text=True)
            self.assertEqual((p.returncode, p.stdout), (0, 'Hello, Warm!\n'), p.stderr)
        args = self.write('Arguments.warm', 'module body Arguments is function main(): ExitCode is for i from 1 to argumentCount() - 1 do printLn(nthArgument(i)); end for; return ExitSuccess(); end; end module body.\n')
        self.assertEqual(self.warm('run', args, 'test', 'arguments').stdout, 'test\narguments\n')
        self.assertEqual(self.warm('run', args, 'a b', '--flag').stdout, 'a b\n--flag\n')
        self.assertEqual(self.warm('run', args, '--', 'a b', '--flag').stdout, 'a b\n--flag\n')
        self.warm('build', args, '-o', 'arguments')
        p = subprocess.run([self.project / 'arguments', 'a b', '--flag'], capture_output=True, text=True)
        self.assertEqual((p.returncode, p.stdout), (0, 'a b\n--flag\n'), p.stderr)

    def test_recursive_module_discovery_interfaces_and_search_path(self):
        self.write('lib/api.warmh', 'module Utility is function number(): Nat64; end module.\n')
        self.write('lib/api.warm', 'module body Utility is function number(): Nat64 is return 42; end; end module body.\n')
        main = self.write('app/Main.warm', 'import Utility (number); module body App is function main(): ExitCode is printLn(number()); return ExitSuccess(); end; end module body.\n')
        self.assertIn('cannot find module Utility', self.warm('run', main, success=False).stderr)
        self.assertEqual(self.warm('run', main, '-I', '../a project/lib').stdout, '42\n')
        self.assertEqual(self.warm('run', '.').stdout, '42\n')
        self.warm('check')
        self.warm('build', '.', '-o', 'app-bin')
        p = subprocess.run([self.project / 'app-bin'], capture_output=True, text=True)
        self.assertEqual((p.returncode, p.stdout), (0, '42\n'), p.stderr)

    def test_standard_library_discovery(self):
        example = ROOT / 'warmc/examples/hello-world/HelloWorld.warm'
        self.assertEqual(self.warm('run', example).stdout, 'Hello, world!\n')

    def test_check_fmt_and_test(self):
        source = self.hello()
        self.warm('check', '.')
        self.warm('fmt', '--check', '.', success=False)
        self.warm('fmt', '.')
        self.warm('fmt', '--check')
        self.write('lib/greeting.warm', 'module body Greeting is function say(): Unit is printLn("HelloTest, Warm!"); return nil; end; end module body.\n')
        self.write('tests/HelloTest.warm', 'import Greeting (say); module body HelloTest is function main(): ExitCode is say(); return ExitSuccess(); end; end module body.\n')
        p = self.warm('test')
        self.assertIn('HelloTest, Warm!', p.stdout)
        self.assertIn('PASS ', p.stdout)
        self.write('tests/HelloTest.warm', 'module body HelloTest is function main(): ExitCode is abort("failed test"); end; end module body.\n')
        self.assertIn('failed test', self.warm('test', success=False).stderr)

    def test_diagnostics_and_coolos_boundary(self):
        source = self.write('Bad.warm', 'import Missing (x); module body Bad is end module body.\n')
        self.assertIn('cannot find module Missing', self.warm('check', source, success=False).stderr)
        source.write_text('import OS.CoolOS.System (System); module body Bad is end module body.\n')
        self.assertIn('requires --coolos', self.warm('check', source, success=False).stderr)
        source.write_text('module body Bad is function main(): ExitCode is return 1; end; end module body.\n')
        self.warm('check', source, success=False)
        source.write_text('module body Bad is function main(): ExitCode is abort("runtime failed"); end; end module body.\n')
        self.assertIn('runtime failed', self.warm('run', source, success=False).stderr)

    def test_ambiguity_and_multiple_entrypoints(self):
        main = self.hello()
        self.write('lib/one.warm', 'module body Utility is end module body.\n')
        self.write('lib/two.warm', 'module body Utility is end module body.\n')
        self.assertIn('ambiguous module Utility', self.warm('check', '.', success=False).stderr)
        (self.project / 'lib/two.warm').unlink()
        self.write('Other.warm', main.read_text().replace('Hello', 'Other'))
        self.assertIn('choose an entrypoint', self.warm('run', '.', success=False).stderr)
        self.assertEqual(self.warm('run', '.', '--entrypoint=Hello:main').stdout, 'Hello, Warm!\n')


if __name__ == '__main__':
    unittest.main()
