#!/usr/bin/env python3
"""Console exit/Exit(): fresh definitions, startup commands and a usable prompt."""
import importlib.util
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('vim_test', ROOT / 'tools/vim-test.py')
vim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vim)


def main():
    kernel, disk, *options = sys.argv[1:]
    for cpus, startup in [(1, True), (2, False)]:
        d = pathlib.Path(disk).parent / f'exit-{cpus}'
        d.mkdir()
        script = vim.BOOT
        script += vim.typed('I64 RestartValue=11;\nexit\n') + vim.BOOT
        script += vim.typed('I64 RestartValue=22;\nPrint("RESTART%d\\n",RestartValue);\n')
        script += vim.wait('RESTART22')
        script += vim.typed('Exit();\n') + vim.BOOT
        script += vim.typed('I64 RestartValue=33;\n')
        if startup:
            script += vim.typed('Cls;\n')  # only defined by Init.cool
        script += vim.typed('Print("FRESH%d\\n",RestartValue);\n') + vim.finish('FRESH33')
        (d / 'input.txt').write_text(script)
        args = ['build/coolvm', '--headless', '--cpus', str(cpus), '--mem', '1024',
                '--timeout', '35', '--width', '640', '--height', '480',
                '--input-script', str(d / 'input.txt')]
        if startup:
            args += ['--disk', disk]
        with (d / 'vm.log').open('wb') as out:
            proc = subprocess.run(['gtimeout', '-k', '2', '40', *args, *options, kernel],
                                  stdout=out, stderr=subprocess.STDOUT)
        log = (d / 'vm.log').read_text(errors='replace').split('SELFTEST PASS', 1)[-1]
        assert proc.returncode == 0, f'console exit VM failed: {d}/vm.log'
        assert log.count('Cool shell:') == 3, f'console was not restarted twice: {d}/vm.log'
        assert log.count('Running C:/Init.cool') == (3 if startup else 0), 'startup rerun count'
        assert 'RESTART22' in log and 'FRESH33' in log, 'fresh compiler did not execute input'
        assert 'ERROR:' not in log and 'Exception:' not in log and 'heap overflow' not in log, log
    print('kernel exit: exit and Exit(), fresh compiler, Init.cool rerun, one/two cores and no startup disk PASS')


if __name__ == '__main__':
    main()
