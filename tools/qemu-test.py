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

# Run on the guest. Keep long definitions off the serial input queue by loading a file.
# Hold the destination with IRQs and its timer masked, queue one SGI, then release
# it into WFI. A pending masked IRQ must wake WFI and complete after IRQ restore.
IPI_PROBE = r"""
I64 qemu_ipi_gate, qemu_ipi_before;
U0 QemuIpiHold(U8 *data)
{
    no_warn data;
    I64 daif = ArchDaif, ctl = ArchCntvCtl;
    ArchIrqOff;
    ArchCntvCtlSet(0);
    ArchStoreRel(&qemu_ipi_gate, 1);
    while (ArchAdd(&qemu_ipi_gate, 0) != 2) {}
    ArchWfi;
    ArchStoreRel(&qemu_ipi_gate, 3);
    ArchCntvCtlSet(ctl);
    ArchIntRestore(daif);
}
U0 QemuIpiAwait(I64 seq)
{
    I64 count;
    while ((count = ArchAdd(&gic_ipi_count[1], 0)) <= qemu_ipi_before) Yield;
    Print("QEMU-IPI-ACK:%d:%d\n", seq, count);
}
U0 QemuIpiQueue()
{
    Spawn(&QemuIpiHold, NULL, "IpiHold", 1);
    while (ArchAdd(&qemu_ipi_gate, 0) != 1) Yield;
    qemu_ipi_before = ArchAdd(&gic_ipi_count[1], 0);
    IntcSendIpi(fdt_cpu[1].mpidr);
    Print("QEMU-IPI-HELD:%d:%d\n", qemu_ipi_before, ArchAdd(&gic_ipi_count[1], 0));
}
U0 QemuIpiRelease()
{
    ArchStoreRel(&qemu_ipi_gate, 2);
    while (ArchAdd(&qemu_ipi_gate, 0) != 3) Yield;
    QemuIpiAwait(0);
}
U0 QemuIpiRound(I64 seq)
{
    qemu_ipi_before = ArchAdd(&gic_ipi_count[1], 0);
    IntcSendIpi(fdt_cpu[1].mpidr);
    QemuIpiAwait(seq);
}
"""


def run(image, accel, gic, read_size=65536):
    outdir = ROOT / 'build' / f'qemu-test-gic{gic}'
    outdir.mkdir(parents=True, exist_ok=True)
    disk = outdir / 'disk.img'
    with disk.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    subprocess.run(['mformat', '-i', str(disk), '-F', '::'], check=True)
    fixture = outdir / 'QEMU.TXT'
    fixture.write_text('QEMU-FILE-READ-PASS\n')
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(fixture), '::QEMU.TXT'], check=True)
    probe = outdir / 'IPI.cool'
    probe.write_text(IPI_PROBE)
    subprocess.run(['mcopy', '-o', '-i', str(disk), str(probe), '::IPI.cool'], check=True)
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
                chunk = os.read(p.stdout.fileno(), read_size)
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
            line('#include "C:/IPI.cool"')
            expect(rb'C:/> ')
            line('QemuIpiQueue;')
            held = expect(rb'\r?\nQEMU-IPI-HELD:(\d+):(\d+)\r?\n')
            previous = int(held[1])
            assert int(held[2]) == previous, 'IPI completed while target IRQs were masked'
            expect(rb'C:/> ')
            for seq in range(17):
                line('QemuIpiRelease;' if seq == 0 else f'QemuIpiRound({seq});')
                # A complete line prevents a pipe chunk ending mid-number from
                # being mistaken for a complete counter. No fixed guest delay:
                # the marker is emitted only after the target has completed EOI.
                ack = expect(rb'\r?\nQEMU-IPI-ACK:(\d+):(\d+)\r?\n')
                assert int(ack[1]) == seq and int(ack[2]) > previous, 'unexpected IPI acknowledgement'
                previous = int(ack[2])
                expect(rb'C:/> ')
            line('Print("QEMU-NET:%d\\n", Ping("10.0.2.2", 1));')
            expect(rb'\r?\nQEMU-NET:1\r?\n')
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
    # Adversarial pipe fragmentation: numeric matches must wait for the newline.
    run(image, 'tcg', 2, read_size=1)


if __name__ == '__main__':
    main()
