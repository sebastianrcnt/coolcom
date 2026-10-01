#!/usr/bin/env python3
"""Changing desktop scale preserves crisp logical pixels and physical backing."""
import subprocess
import sys
import testvm
from testvm import ROOT
OUT=ROOT / 'build/gui-scale-test'
KERNEL=sys.argv[1]

def boot(mode,scale):
    d=OUT / f'{mode}-{scale}x'
    d.mkdir(parents=True,exist_ok=True)
    disk=d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk,stdout=subprocess.DEVNULL)
    if mode=='venus': subprocess.run([ROOT / 'tools/venus/install.sh',disk],check=True,stdout=subprocess.DEVNULL)
    script=testvm.BOOT+testvm.typed('FontSet(NULL); Gui;\n')+'wait GUI WINDOWS READY\n'+testvm.typed('GuiSettings;\n')+'wait GUI SETTINGS READY\n'
    if scale==2:
        script+=testvm.pointer_absolute(304,165,800,600)+'delay 40\n1 272 1\ndelay 40\n1 272 0\nwait GUI SETTINGS SCALE2\nwait GUI SCALE APPLIED\n'
    else:
        script+=testvm.pointer_absolute(152,82,400,300)
    script+='delay 200\nquit\n'
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(KERNEL,executable=ROOT / ('build/coolvm-venus' if mode=='venus' else 'build/coolvm'),no_venus=mode=='cpu',size=(400*scale,300*scale),scale=1,
        timeout=80,host_timeout=100,disk=disk,input_script=d / 'input.txt',screenshot=d / 'screen.png'),d / 'vm.log',stdin=subprocess.DEVNULL,check=True)
    log=(d / 'vm.log').read_text(errors='replace')
    assert not any(s in log for s in ['ERROR:','VENUS FAIL','Error:']),log[-2500:]
    print(f'gui-scale-test: {mode}-{scale}x PASS',flush=True)
    return testvm.read_png(d / 'screen.png')

one=boot('cpu',1)
two=boot('cpu',2)
for y in range(one[1]):
    limit=one[0]-60 if y<21 else one[0]
    for x in range(limit):
        p=one[2][y][3*x:3*x+3]
        for dy in range(2):
            assert two[2][2*y+dy][6*x:6*x+6]==p+p,f'scale resize mismatch {x},{y}'
if '--venus' in sys.argv:
    gpu=boot('venus',2)
    for y in range(two[1]):
        end=3*(two[0]-120) if y<42 else 3*two[0]
        assert two[2][y][:end]==gpu[2][y][:end],f'scale CPU/Venus mismatch row {y}'
print('gui-scale-test: G4 integer enlargement PASS',flush=True)
