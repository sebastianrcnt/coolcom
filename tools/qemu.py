#!/usr/bin/env python3
"""Shared QEMU virt launcher. Serial console until virtio-gpu is available."""
import argparse
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
QEMU = os.environ.get('QEMU', 'qemu-system-aarch64')


def accelerator():
    selected = os.environ.get('QEMU_ACCEL', 'auto')
    if selected != 'auto':
        if selected not in ('hvf', 'tcg'):
            raise ValueError('QEMU_ACCEL must be auto, hvf or tcg')
        return selected
    # Probe actual VM creation, rather than merely checking compiled-in accelerators.
    try:
        subprocess.run([QEMU, '-M', 'virt,gic-version=3', '-accel', 'hvf',
                                 '-cpu', 'host', '-display', 'none', '-serial', 'none',
                                 '-monitor', 'none', '-S'], capture_output=True, timeout=1)
    except subprocess.TimeoutExpired:
        return 'hvf'
    return 'tcg'


def command(image, disk, accel, gic=3):
    return [QEMU, '-M', f'virt,gic-version={gic}', '-accel', accel,
            '-cpu', 'host' if accel == 'hvf' else 'max', '-smp', '2', '-m', '1024',
            '-kernel', str(image), '-display', 'none', '-serial', 'stdio', '-monitor', 'none',
            '-global', 'virtio-mmio.force-legacy=false',
            '-drive', f'if=none,id=disk,file={disk},format=raw',
            '-device', 'virtio-blk-device,drive=disk',
            '-netdev', 'user,id=net', '-device', 'virtio-net-device,netdev=net']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=pathlib.Path)
    parser.add_argument('disk', type=pathlib.Path)
    args = parser.parse_args()
    accel = accelerator()
    gic = int(os.environ.get('QEMU_GIC', '3'))
    print(f'QEMU virt: {accel}, GICv{gic}; Ctrl+A X exits QEMU', flush=True)
    # Explicitly multiplex the monitor and UART for Ctrl+A X / Ctrl+A C.
    cmd = command(args.image, args.disk, accel, gic)
    cmd[cmd.index('-serial') + 1] = 'mon:stdio'
    os.execvp(QEMU, cmd)


if __name__ == '__main__':
    main()
