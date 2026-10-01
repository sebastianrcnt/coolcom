#!/usr/bin/env python3
"""Existing Venus Cube in a desktop window: scene, input, geometry, lifetime."""
import re
import subprocess
import sys
import testvm
from testvm import ROOT
KERNEL=sys.argv[1]
OUT=ROOT / 'build/gui-cube-test'

def boot(name,lifecycle=False,cpu=False):
    d=OUT / name
    d.mkdir(parents=True,exist_ok=True)
    disk=d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk,stdout=subprocess.DEVNULL)
    if not cpu:
        subprocess.run([ROOT / 'tools/venus/install.sh',disk],check=True,stdout=subprocess.DEVNULL)
        for shader in (ROOT / 'build/venus').glob('cube.*.spv'):
            subprocess.run(['mcopy','-o','-i',disk,shader,'::Vulkan/'],check=True)
    script=testvm.BOOT+testvm.typed('FontSet(NULL); Gui;\n')+'wait GUI WINDOWS READY\n'
    script+=testvm.typed('I64 cb=0,ci; for(ci=0;ci<GPU_VENUS_BLOBS;ci++) if(venus.blobs[ci].id) cb++; GuiCube;\n')
    if cpu:
        script+='wait Cube needs\ndelay 100\nquit\n'
    else:
        script+='wait CUBE WINDOW READY\n'+testvm.typed(' ')+testvm.keys_of(106)+'wait CUBE WINDOW KEY\n'
        # Move (68,82) to (108,112), then grow the lower-right box.
        script+=testvm.pointer_absolute(200,90,800,600)+'delay 40\n1 272 1\ndelay 40\n'+testvm.pointer_absolute(240,120,800,600)+'delay 40\n1 272 0\ndelay 40\n'
        script+=testvm.pointer_absolute(590,448,800,600)+'delay 40\n1 272 1\ndelay 40\n'+testvm.pointer_absolute(654,480,800,600)+'delay 40\n1 272 0\ndelay 40\n'
        script+='wait CUBE WINDOW SIZE 540x328\n'
        if lifecycle:
            script+=testvm.typed('q')+'wait CUBE CLOSED\ndelay 100\n'
            script+=testvm.typed('I64 ca=0; for(ci=0;ci<GPU_VENUS_BLOBS;ci++) if(venus.blobs[ci].id) ca++; Print("GCUBELIFE%d %d %d\\n",1,cb,ca); GuiCube;\n')+'wait GCUBELIFE1\nwait CUBE WINDOW READY\n'
            script+=testvm.typed('q')+'wait CUBE CLOSED\ndelay 100\n'
        script+='delay 100\nquit\n'
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(KERNEL,executable=ROOT / ('build/coolvm' if cpu else 'build/coolvm-venus'),
        no_venus=cpu,size=(800,600),scale=1,timeout=90,host_timeout=110,disk=disk,input_script=d / 'input.txt',screenshot=d / 'screen.png'),
        d / 'vm.log',stdin=subprocess.DEVNULL,check=True)
    log=(d / 'vm.log').read_text(errors='replace')
    assert not any(s in log for s in ['ERROR:','VENUS FAIL','graphics error','Exception:']),log[-3500:]
    if lifecycle:
        match=re.search(r'GCUBELIFE1 (\d+) (\d+)',log)
        assert match and match[1]==match[2],log[-1500:]
        assert log.count('CUBE CLOSED frames=')==2,log[-1500:]
    elif not cpu:
        w,h,rows=testvm.read_png(d / 'screen.png')
        pixel=lambda x,y:tuple(rows[y][3*x:3*x+3])
        colored=sum(1 for y in range(145,430) for x in range(116,640) if max(pixel(x,y))-min(pixel(x,y))>45)
        assert colored>10000,colored
        assert pixel(108,180)==(0,0,0) and pixel(109,180)==(255,255,255),'cube window frame/inset'
        assert pixel(700,500) in [(0,0,0),(255,255,255)],'cube stays inside window'
    print(f'gui-cube-test: {name} PASS',flush=True)

boot('preview')
boot('lifecycle',lifecycle=True)
boot('cpu',cpu=True)
