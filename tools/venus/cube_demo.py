#!/usr/bin/env python3
"""Launch the Cool cube demo, or exercise it on the real Venus GPU in a scratch VM."""
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ('build/cube-demo' if '--run' in sys.argv else 'build/cube-test')


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


keys = load('cube_keys', ROOT / 'tools/testvm.py')
verify = keys


def command(args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True,
                   stdout=subprocess.DEVNULL)


def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    disk = OUT / 'demo.img'
    with disk.open('wb') as file:
        file.truncate(64 << 20)
    command(['mformat', '-i', disk, '-F', '::'])
    command([ROOT / 'tools/disk-files.sh', disk])
    command([ROOT / 'tools/venus/install.sh', disk])
    for path in (ROOT / 'build/venus').glob('cube.*.spv'):
        command(['mcopy', '-o', '-i', disk, path, '::Vulkan/'])
    # Load just the application; normal shells can load it on demand without
    # making the default OS boot depend on optional Vulkan files.
    init = OUT / 'Init.cool'
    init.write_text('#include "C:/Cube.cool"\n')
    command(['mcopy', '-o', '-i', disk, init, '::Init.cool'])
    return disk


def run(name, disk, script, markers=(), no_venus=False, allow_graphics_error=False):
    path = OUT / f'{name}.input'
    path.write_text(keys.BOOT + script)
    log = OUT / f'{name}.log'
    png = OUT / f'{name}.png'
    args = [ROOT / 'build/coolvm-venus', '--headless', '--cpus', '2', '--mem', '1024',
            '--width', '960', '--height', '640', '--timeout', '90', '--disk', disk,
            '--input-script', path, '--screenshot', png, ROOT / 'build/kernel.Image']
    if no_venus:
        args.insert(1, '--no-venus')
    with log.open('wb') as output:
        proc = subprocess.Popen([str(arg) for arg in args], cwd=ROOT, stdout=output,
                                stderr=subprocess.STDOUT,
                                env=dict(os.environ, MVK_CONFIG_LOG_LEVEL='1'))
        deadline = time.monotonic() + 100
        while proc.poll() is None:
            current = log.read_text(errors='replace').split('Running C:/Init.cool', 1)
            if len(current) == 2 and any(word in current[1] for word in ['ERROR:', 'VENUS FAIL', 'compiler exited']):
                proc.terminate()
                break
            if time.monotonic() > deadline:
                proc.kill()
                break
            time.sleep(0.1)
        proc.wait(timeout=5)
    text = log.read_text(errors='replace')
    guest = text.split('Running C:/Init.cool', 1)[-1]
    assert proc.returncode == 0, f'{name}: VM exit {proc.returncode}; see {log}'
    errors = ['ERROR:', 'VENUS FAIL', 'compiler exited', 'Exception:']
    if not allow_graphics_error:
        errors.append('graphics error')
    assert not any(word in guest for word in errors), guest[-6000:]
    for marker in markers:
        assert marker in guest, f'{name}: missing {marker}; see {log}'
    print(f'cube-test: {name} PASS ({log.relative_to(ROOT)})', flush=True)
    return verify.read_png(png), guest


def launch():
    # Keep the normal disk untouched, including when another VM is using it.
    disk = prepare()
    path = OUT / 'launch.input'
    path.write_text(keys.BOOT + keys.typed('Cube;\n'))
    subprocess.run([str(ROOT / 'build/coolvm-venus'), '--cpus', '2', '--mem', '1024',
                    '--width', '960', '--height', '640', '--disk', str(disk),
                    '--input-script', str(path), str(ROOT / 'build/kernel.Image')],
                   cwd=ROOT, check=True, env=dict(os.environ, MVK_CONFIG_LOG_LEVEL='1'))


def main():
    if '--run' in sys.argv:
        launch()
        return
    disk = prepare()
    start = keys.typed('Cube;\n') + 'wait CUBE READY\n'
    preview, _ = run('preview', disk, start + keys.typed(' ') + 'delay 200\nquit\n', ['CUBE READY'])
    width, height, rows = preview
    assert (width, height) == (960, 640)
    # The scene must contain a substantial colored solid, visible floor, and HUD.
    blue = sum(1 for y in range(120, 500) for x in range(180, 780)
               if rows[y][3*x+2] > rows[y][3*x] * 1.5 and rows[y][3*x+2] > 90)
    orange = sum(1 for row in rows for x in range(width)
                 if row[3*x] > 100 and row[3*x] > row[3*x+2] * 1.5)
    hud = sum(1 for y in range(24, 45) for x in range(26, 190)
              if rows[y][3*x] > 180 and rows[y][3*x+1] > 200)
    assert blue > 5000 and orange > 300 and hud > 100, (blue, orange, hud)
    turned, _ = run('camera', disk, start + keys.typed(' ') + keys.keys_of(106) * 6 +
                    keys.typed('wwa') + 'delay 200\nquit\n', ['CUBE READY'])
    assert turned[:2] == preview[:2]
    difference = sum(1 for a, b in zip(rows, turned[2]) for x in range(width)
                     if a[3*x:3*x+3] != b[3*x:3*x+3])
    assert difference > width * height * 0.15, difference
    # Bounds, pause/reset, repeated runs, and restoration of the resident terminal.
    setup = keys.typed('I64 cb=0,ci; for(ci=0;ci<GPU_VENUS_BLOBS;ci++) if(venus.blobs[ci].id) cb++; Cube;\n')
    controls = ('wait CUBE READY\n' + keys.typed(' ') + keys.keys_of(106) + keys.keys_of(103) +
                keys.typed('wwadq') + 'wait CUBE CLOSED\n')
    checks = keys.typed('Print("STATE%d %d %d %d %d\\n",1,cube.params.yaw,cube.params.pitch,cube.params.distance,cube.paused); Cube(3);\n')
    repeat = ('wait CUBE CLOSED\n' + keys.typed('I64 ca=0; for(ci=0;ci<GPU_VENUS_BLOBS;ci++) if(venus.blobs[ci].id) ca++; Print("LIFE%d %d %d %d\\n",1,cb,ca,fb.venus);\n') +
              'wait LIFE1\ndelay 200\nquit\n')
    _, log = run('lifecycle', disk, setup + controls + checks + repeat,
                 ['STATE1 540 350 6060 1', 'LIFE1'])
    match = re.search(r'LIFE1 (\d+) (\d+) (\d+)', log)
    assert match and match[1] == match[2] and match[3] == '1', log[-2000:]
    # A shell break must release the renderer lock and leave the GPU terminal usable.
    interrupt = ('1 29 1\n1 56 1\n' + keys.keys_of(46) + '1 56 0\n1 29 0\n')
    script = start + interrupt + 'wait > \n' + keys.typed('Print("BREAK%d %d %d\\n",1,cube.active,fb.render_lock); Cube(2);\n')
    run('break', disk, script + 'wait CUBE CLOSED\ndelay 200\nquit\n', ['BREAK1 0 0', 'CUBE CLOSED'])
    resized, _ = run('resize', disk, start + 'resize 800 600\ndelay 700\nquit\n', ['CUBE READY'])
    assert resized[:2] == (800, 600), resized[:2]
    # Clamp the camera, then reset while running; an extreme key sequence must
    # not enter a cube or turn the camera upside down.
    bounds = (start + keys.typed('w' * 24) + keys.keys_of(103) * 24 + keys.typed('a' * 60 + 'q') +
              'wait CUBE CLOSED\n' + keys.typed('Print("BOUND%d %d %d %d\\n",1,cube.params.distance,cube.params.pitch,cube.params.pan_x); Cube;\n') +
              'wait CUBE READY\n' + keys.typed(' r') + 'delay 50\n' + keys.typed('q') +
              'wait CUBE CLOSED\n' + keys.typed('Print("RESET%d %d %d %d %d %d\\n",1,cube.params.yaw,cube.params.pitch,cube.params.distance,cube.params.pan_x,cube.paused);\n') +
              'wait RESET1\nquit\n')
    run('bounds-reset', disk, bounds, ['BOUND1 2800 1200 -8000', 'RESET1 450 280 6500 0 0'])
    run('fallback', disk, keys.typed('Cube;\n') + 'wait Cube needs\nwait > \nquit\n',
        ['Cube needs the Venus terminal'], no_venus=True)
    # Leave room for the demo's reply blob, but not its readback blob. This
    # exercises cleanup after the image, buffer and memory already exist.
    failure = OUT / 'Failure.cool'
    failure.write_text('''#include "C:/Cube.cool"
I64 i, before=0, after=0, count=0;
CGpuBlob *held[GPU_VENUS_BLOBS];
for(i=0;i<GPU_VENUS_BLOBS;i++) if(venus.blobs[i].id) before++;
while(count<GPU_VENUS_BLOBS-before-1) {
    held[count]=GpuBlobCreate(16384,GPU_BLOB_GUEST);
    if(!held[count]) throw('CubeTest');
    count++;
}
Cube(2);
for(i=0;i<count;i++) GpuBlobDestroy(held[i]);
for(i=0;i<GPU_VENUS_BLOBS;i++) if(venus.blobs[i].id) after++;
Print("FAILURE1 %d %d %d %d\\n",before,after,cube.active,fb.render_lock);
Cube(2);
''')
    command(['mcopy', '-o', '-i', disk, failure, '::Init.cool'])
    _, log = run('allocation-failure', disk, 'quit\n', ['FAILURE1', 'CUBE READY'], allow_graphics_error=True)
    match = re.search(r'FAILURE1 (\d+) (\d+) (\d+) (\d+)', log)
    assert match and match[1] == match[2] and match[3] == match[4] == '0', log[-3000:]
    print(f'cube-test: real GPU pixels PASS (blue={blue}, orange={orange}, HUD={hud}, changed={difference})')


if __name__ == '__main__':
    main()
