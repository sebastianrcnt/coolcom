#!/usr/bin/env python3
"""Console exit/Exit(): fresh definitions, startup commands and a usable prompt."""
import pathlib
import sys

import testvm


def main():
    kernel, disk, *options = sys.argv[1:]
    for cpus, startup in [(1, True), (2, False)]:
        d = pathlib.Path(disk).parent / f'exit-{cpus}'
        d.mkdir()
        script = testvm.BOOT
        script += testvm.typed('I64 RestartValue=11;\nexit\n') + testvm.BOOT
        script += testvm.typed('I64 RestartValue=22;\nPrint("RESTART%d\\n",RestartValue);\n')
        script += testvm.wait('RESTART22')
        script += testvm.typed('Exit();\n') + testvm.BOOT
        script += testvm.typed('I64 RestartValue=33;\n')
        if startup:
            script += testvm.typed('Cls;\n')  # only defined by Init.cool
        script += testvm.typed('Print("FRESH%d\\n",RestartValue);\n') + testvm.finish('FRESH33')
        (d / 'input.txt').write_text(script)
        proc = testvm.run_vm(testvm.vm_command(kernel, no_venus=True, cpus=cpus,
            timeout=35, input_script=d / 'input.txt', disk=disk if startup else None,
            size=(640, 480), extra=options, host_timeout=40), d / 'vm.log')
        log = (d / 'vm.log').read_text(errors='replace').split('SELFTEST PASS', 1)[-1]
        assert proc.returncode == 0, f'console exit VM failed: {d}/vm.log'
        assert log.count('Cool shell:') == 3, f'console was not restarted twice: {d}/vm.log'
        assert log.count('Running C:/Init.cool') == (3 if startup else 0), 'startup rerun count'
        assert 'RESTART22' in log and 'FRESH33' in log, 'fresh compiler did not execute input'
        assert 'ERROR:' not in log and 'Exception:' not in log and 'heap overflow' not in log, log
    print('kernel exit: exit and Exit(), fresh compiler, Init.cool rerun, one/two cores and no startup disk PASS')


if __name__ == '__main__':
    main()
