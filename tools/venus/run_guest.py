#!/usr/bin/env python3
"""Run an actual guest Venus client on the real optional renderer."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import time
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'build/venus-test'
OUT.mkdir(parents=True, exist_ok=True)
def run(args):
    subprocess.run([str(a) for a in args], cwd=ROOT, check=True)
def guest(source, name, screenshot=False):
    image=OUT/f'{name}.png'
    if screenshot: image.unlink(missing_ok=True)
    disk=OUT/f'{name}.img'
    with disk.open('wb') as f: f.truncate(64<<20)
    run(['mformat','-i',disk,'-F','::'])
    run(['mmd','-i',disk,'::Vulkan'])
    for p in [ROOT/'build/venus/Vulkan.cool',ROOT/'os/Vulkan/Gfx.cool']:
        run(['mcopy','-o','-i',disk,p,'::Vulkan/'])
    if screenshot:
        for p in (ROOT/'build/venus').glob('triangle.*.spv'):
            run(['mcopy','-o','-i',disk,p,'::Vulkan/'])
    run(['mcopy','-o','-i',disk,source,'::Init.cool'])
    log=OUT/f'{name}.log'
    command=[ROOT/'build/coolvm-venus','--headless','--no-logos','--cpus','2','--mem','1024','--timeout','120','--disk',disk,ROOT/'build/kernel.Image']
    if screenshot: command[1:1]=['--screenshot',OUT/f'{name}.png']
    with log.open('wb') as out:
        p=subprocess.Popen([str(a) for a in command],cwd=ROOT,stdout=out,stderr=subprocess.STDOUT,
                           env=dict(os.environ,MVK_CONFIG_LOG_LEVEL='1'))
        deadline=time.monotonic()+135
        while p.poll() is None:
            current=log.read_text(errors='replace')
            guest_log=current.split('Running C:/Init.cool',1)
            if len(guest_log)==2 and any(x in guest_log[1] for x in ['ERROR:', 'VENUS FAIL', 'Exception:']):
                p.terminate(); break
            if time.monotonic()>deadline: p.kill(); break
            time.sleep(0.1)
        p.wait(timeout=5)
    text=log.read_text(errors='replace')
    if p.returncode or f'VENUS {name.upper()} PASS' not in text or 'VENUS FAIL' in text:
        raise SystemExit(f'{name} failed: {log}\n'+text[-6000:])
    print(f'venus-{name}-test: guest PASS ({log})')
    if screenshot: check_triangle(image)
def check_triangle(path):
    spec=importlib.util.spec_from_file_location('verify',ROOT/'tools/kernel-verify.py')
    verify=importlib.util.module_from_spec(spec); spec.loader.exec_module(verify)
    width,height,rows=verify.read_png(path)
    assert (width,height)==(256,256), f'wrong scanout dimensions: {width}x{height}'
    checked=painted=0
    for y,row in enumerate(rows):
        for x in range(width):
            rgb=tuple(row[3*x:3*x+3])
            if rgb[0]>200: painted+=1
            # Analytic coverage from shader vertices, excluding rasterization edges.
            px,py=x+0.5,y+0.5
            left=32+(py-32)/2; right=224-(py-32)/2
            if min(abs(py-32),abs(py-224),abs(px-left),abs(px-right))<1.5: continue
            inside=32<py<224 and left<px<right
            expected=(230,51,26) if inside else (13,26,51)
            assert all(abs(a-b)<=1 for a,b in zip(rgb,expected)), f'pixel ({x},{y})={rgb}, expected {expected}'
            checked+=1
    assert 18000<painted<19000, f'wrong triangle area: {painted}'
    print(f'venus-test: screenshot PASS ({checked} checked pixels; {painted} triangle pixels; {path})')

if __name__=='__main__':
    if '--triangle' in sys.argv: guest(ROOT/'tools/venus/triangle-test.cool','triangle',True)
    else: guest(ROOT/'tools/venus/coherence-test.cool','memory')
