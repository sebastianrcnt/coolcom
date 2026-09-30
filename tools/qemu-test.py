#!/usr/bin/env python3
"""Boot QEMU virt, read a FAT file at the shell, test IPI/reset and PSCI shutdown."""
import os
import pathlib
import re
import selectors
import subprocess
import sys
import time

import qemu

ROOT = qemu.ROOT


def run(image, accel, gic):
    outdir = ROOT / 'build' / f'qemu-test-gic{gic}'
    outdir.mkdir(parents=True, exist_ok=True)
    disk = outdir / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '::'], check=True)
    fixture = outdir / 'QEMU.TXT'
    fixture.write_text('QEMU-FILE-READ-PASS\n')
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(fixture), '::QEMU.TXT'], check=True)
    cmd = qemu.command(image, disk, accel, gic)
    with (outdir / 'serial.log').open('wb') as log:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        sel = selectors.DefaultSelector()
        sel.register(p.stdout, selectors.EVENT_READ)
        pending = b''
        transcript = b''

        def expect(pattern, timeout=30):
            nonlocal pending, transcript
            deadline = time.monotonic() + timeout
            regex = re.compile(pattern)
            while True:
                match = regex.search(pending)
                if match:
                    pending = pending[match.end():]
                    return match
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise AssertionError(f'timed out waiting for {pattern!r}; see {outdir}/serial.log')
                if not sel.select(min(remaining, 1)):
                    continue
                chunk = os.read(p.stdout.fileno(), 65536)
                if not chunk:
                    raise AssertionError(f'QEMU exited before {pattern!r}; see {outdir}/serial.log')
                log.write(chunk)
                log.flush()
                transcript += chunk
                pending += chunk

        def line(text):
            p.stdin.write((text + '\n').encode())
            p.stdin.flush()

        try:
            expect(rb'SELFTEST PASS')
            expect(rb'2 cores online')
            expect(rb'network: virtio-net')
            expect(rb'C:/> ')
            line('U8 *q = FileRead("C:/QEMU.TXT"); Print("%s", q); Free(q);')
            expect(rb'\r?\nQEMU-FILE-READ-PASS\r?\n')
            expect(rb'C:/> ')
            line('Print("IPI-BEFORE:%d\\n", ipi_count);')
            before = int(expect(rb'\r?\nIPI-BEFORE:(\d+)')[1])
            expect(rb'C:/> ')
            line('IntcSendIpi(fdt_cpu[1].mpidr); Sleep(20); Print("IPI-AFTER:%d\\n", ipi_count);')
            after = int(expect(rb'\r?\nIPI-AFTER:(\d+)')[1])
            assert after > before, f'IPI was not acknowledged; see {outdir}/serial.log'
            expect(rb'C:/> ')
            line('Print("QEMU-NET:%d\\n", Ping("10.0.2.2", 1));')
            expect(rb'\r?\nQEMU-NET:1')
            expect(rb'C:/> ')
            line('Reboot;')
            expect(rb'Rebooting\.')
            expect(rb'coolcom kernel')
            expect(rb'2 cores online')
            expect(rb'C:/> ')
            line('Shutdown;')
            expect(rb'Power off\.')
            assert p.wait(timeout=10) == 0, 'QEMU shutdown exit status'
            assert b'*** Exception:' not in transcript and b'SELFTEST FAIL' not in transcript
            print(f'qemu-test: GICv{gic} {accel}: 2 cores, file read, IPI, network, reset, power off PASS')
        finally:
            sel.close()
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()


def main():
    image = pathlib.Path(sys.argv[1]).resolve()
    run(image, qemu.accelerator(), 3)
    # HVF only exposes GICv3; exercise the MMIO GICv2 interface with TCG.
    run(image, 'tcg', 2)


if __name__ == '__main__':
    main()
