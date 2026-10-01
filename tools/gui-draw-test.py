#!/usr/bin/env python3
"""Pixel windows, clipped Gr drawing, ordered local input, and bounded response.
Uses the shared testvm harness; artifacts are isolated from G1 tests.
"""
import pathlib
import re
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
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n' + testvm.typed('if(gui.count!=1)throw(90); GuiShell;\n') + 'wait GUI SHELL OPEN\n'
    fixture = d / 'Burst.cool'
    fixture.write_text('''U0 GuiDrawBurst()
{
    I64 i,daif;CGuiWindow *w=NULL;
    for(i=0;i<gui.count;i++)if(gui.windows[i]->pixel)w=gui.windows[i];
    GuiFocus(w);
    // One raw-input backlog, so no consumer can run until the compositor pumps it.
    daif=ArchDaif;ArchIrqOff;
    for(i=0;i<80;i++)GuiKey('p');
    ArchIntRestore(daif);
}
''')
    subprocess.run(['mcopy', '-o', '-i', disk, fixture, '::Burst.cool'], check=True)
    script += testvm.typed('#include "C:/Burst.cool"\n')
    script += testvm.typed('GuiDraw; GuiDraw; GuiDraw;\n') + 'wait GUI DRAW READY5\n'
    # Move from (400,300) to (140,205): local (20,50) in the last window.
    script += testvm.pointer_absolute(140, 205, 800, 600) + '1 272 1\n1 272 0\nwait GUI DRAW MOUSE 20 50\n'
    # An entire burst must survive unchanged even with five windows.
    for _ in range(80):
        script += testvm.typed('p', delay=0)
    script += 'wait GUI DRAW PONG \n' * 80 + 'wait GUI DRAW PRESENTED\n'
    script += testvm.pointer_absolute(200, 65, 800, 600) + 'delay 20\n1 272 1\ndelay 20\n1 272 0\ndelay 20\n'
    script += testvm.typed('GuiDrawBurst;\n')
    if '--diagnose-burst' in sys.argv:
        script += 'wait GUI DRAW PRESENTED\ndelay 100\nquit\n'
    else:
        script += 'wait GUI DRAW PONG \n' * 80 + 'wait GUI DRAW PRESENTED\nquit\n'
    (d / 'input.txt').write_text(script)
    vm = ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm')
    testvm.run_vm(testvm.vm_command(KERNEL, executable=vm, no_venus=mode == 'cpu', size=(800, 600),
        scale=1, timeout=80, host_timeout=100, disk=disk, input_script=d / 'input.txt', screenshot=d / 'screen.png'),
        d / 'vm.log', stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert 'ERROR:' not in log and 'VENUS FAIL' not in log, log[-2000:]
    responses = [tuple(map(int, match.groups())) for match in re.finditer(r'GUI DRAW PONG (\d+) (\d+)\r?\n', log)]
    times = [r[0] for r in responses]
    if '--diagnose-burst' in sys.argv:
        print(f'gui-draw-diagnose: {mode}, first={min(len(times),80)}, backlog={len(times)-80}, lost={"GUI DRAW INPUT LOST" in log}', flush=True)
        return testvm.read_png(d / 'screen.png')
    assert 'GUI DRAW INPUT LOST' not in log, f'{mode}: window event queue overflow'
    assert max((r[1] for r in responses), default=1000) <= 100, f'{mode}: input dispatch exceeded 100 ms'
    assert len(times) == 160, f'{mode}: only {len(times)} of 160 keys delivered'
    for start in (0,80):
        duration = times[start+79]-times[start]
        assert duration <= 100, f'{mode}: key burst took {duration} ms'
    w, h, rows = testvm.read_png(d / 'screen.png')
    pixel = lambda x, y: tuple(rows[y][3*x:3*x+3])
    assert pixel(140, 205) == (0, 0, 0), 'mouse painting at local coordinates'
    assert pixel(220, 205) == (0, 170, 255), 'GrRect color'  # clear of the arrow at (140, 205)
    assert pixel(183, 228) == (255, 170, 0), 'overlapping rectangle'
    assert pixel(120, 155) == (255, 255, 255), 'pixel client origin'
    print(f'gui-draw-test: {mode}, five windows, local click, 80 host keys / 80 queued keys in {times[79]-times[0]} / {times[159]-times[80]} ms PASS', flush=True)
    return w, h, rows


cpu = boot('cpu')
if '--venus' in sys.argv:
    gpu = boot('venus')
    for y in range(cpu[1]):
        end = 3 * (cpu[0] - 60) if y < 21 else 3 * cpu[0]
        assert cpu[2][y][:end] == gpu[2][y][:end], f'pixel surface CPU/Venus mismatch row {y}'
print('gui-draw-diagnose: complete' if '--diagnose-burst' in sys.argv else 'gui-draw-test: G2 PASS', flush=True)
