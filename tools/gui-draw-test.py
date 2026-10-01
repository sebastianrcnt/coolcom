#!/usr/bin/env python3
"""Pixel windows, clipped Gr drawing, ordered local input, and bounded response.
Uses the shared testvm harness; artifacts are isolated from G1 tests.
"""
import pathlib
import subprocess
import sys
import testvm
from testvm import ROOT
OUT = ROOT / 'build/gui-draw-test'
OUT.mkdir(parents=True, exist_ok=True)
KERNEL = sys.argv[1]


def boot(mode):
    d = OUT / mode
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    if mode == 'venus':
        subprocess.run([ROOT / 'tools/venus/install.sh', disk], check=True, stdout=subprocess.DEVNULL)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n'
    script += testvm.typed('GuiDraw; GuiDraw; GuiDraw;\n') + 'wait GUI DRAW READY5\n'
    # Move from (400,300) to (140,205): local (20,50) in the last window.
    script += '2 0 -260\n2 1 -95\n1 272 1\n1 272 0\nwait GUI DRAW MOUSE 20 50\n'
    # An entire burst must survive unchanged even with five windows.
    for _ in range(80):
        script += testvm.typed('p', delay=0)
    script += 'delay 100\nquit\n'
    (d / 'input.txt').write_text(script)
    vm = ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm')
    testvm.run_vm(testvm.vm_command(KERNEL, executable=vm, no_venus=mode == 'cpu', size=(800, 600),
        scale=1, timeout=80, host_timeout=100, disk=disk, input_script=d / 'input.txt', screenshot=d / 'screen.png'),
        d / 'vm.log', stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert 'ERROR:' not in log and 'VENUS FAIL' not in log, log[-2000:]
    responses = [tuple(map(int, l.split()[-2:])) for l in log.splitlines() if l.startswith('GUI DRAW PONG ')]
    times = [r[0] for r in responses]
    assert max((r[1] for r in responses), default=1000) <= 100, f'{mode}: input dispatch exceeded 100 ms'
    assert len(times) == 80, f'{mode}: only {len(times)} of 80 keys delivered'
    assert times[-1] - times[0] <= 100, f'{mode}: key burst took {times[-1] - times[0]} ms'
    w, h, rows = testvm.read_png(d / 'screen.png')
    pixel = lambda x, y: tuple(rows[y][3*x:3*x+3])
    assert pixel(140, 205) == (0, 0, 0), 'mouse painting at local coordinates'
    assert pixel(143, 210) == (0, 170, 255), 'GrRect color'
    assert pixel(183, 228) == (255, 170, 0), 'overlapping rectangle'
    assert pixel(120, 155) == (255, 255, 255), 'pixel client origin'
    print(f'gui-draw-test: {mode}, five windows, local click, 80 keys in {times[-1]-times[0]} ms PASS', flush=True)
    return w, h, rows


cpu = boot('cpu')
if '--venus' in sys.argv:
    gpu = boot('venus')
    for y in range(cpu[1]):
        end = 3 * (cpu[0] - 60) if y < 21 else 3 * cpu[0]
        assert cpu[2][y][:end] == gpu[2][y][:end], f'pixel surface CPU/Venus mismatch row {y}'
print('gui-draw-test: G2 PASS', flush=True)
