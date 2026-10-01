#!/usr/bin/env python3
"""Standard guest cursor queue, native view cursor, scale/hotspot and exports."""
import os
import re
import subprocess
import sys
import testvm
from testvm import ROOT
KERNEL=sys.argv[1]
OUT=ROOT / 'build/gui-cursor-test'
# An original asymmetric shape with transparency and a nonzero hotspot.
SHAPE=[0,0xff000000,0xffffffff,0,
       0xff000000,0x80000000,0xffffffff,0,
       0,0xffffffff,0xff000000,0xff000000,
       0,0,0xff000000,0]


def boot(mode,scale,ending='shape',window=False):
    name=f'{mode}-{scale}x-{ending}'+('-window' if window else '')
    d=OUT / name;d.mkdir(parents=True,exist_ok=True)
    disk=d / 'disk.img';testvm.create_disk(disk);testvm.install_disk_files(disk,stdout=subprocess.DEVNULL)
    if mode=='venus':subprocess.run([ROOT / 'tools/venus/install.sh',disk],check=True,stdout=subprocess.DEVNULL)
    fixture=d / 'Cursor.cool'
    fixture.write_text('''U0 CursorProbe()
{
    U32 shape[16];
    '''+''.join(f'shape[{i}]={hex(v)};' for i,v in enumerate(SHAPE))+'''
    if (GuiPointerSet(shape,33,4) || GuiPointerSet(shape,4,4,4,0)) throw(5);
    if (!GuiPointerSet(shape,4,4,1,2)) throw(6);
    GuiPointerHide; if (gpu.cursor_on) throw(7);
    if (!GuiPointerShow || !gpu.cursor_on) throw(8);
    U8 *m=MStrPrint("CURSOR SHAPE%d\\n",1);GuiLog(m);Free(m);
}
U0 CursorCheck()
{
    I64 x,y,s=gui.scale;
    for(y=gui.my*s-4*s;y<(gui.my+6)*s;y++) for(x=gui.mx*s-4*s;x<(gui.mx+6)*s;x++)
        if (gui.canvas[y*fb.w+x]!=gui.desktop[y*fb.w+x]) throw(9);
    U8 *m=MStrPrint("CURSOR CANVAS%d\\n",1);GuiLog(m);Free(m);
}
''')
    subprocess.run(['mcopy','-o','-i',disk,fixture,'::Cursor.cool'],check=True)
    script=testvm.BOOT+testvm.typed(f'FontSet(NULL); FontScale({scale}); Gui;\n')+'wait GUI WINDOWS READY\n' + testvm.typed('if(gui.count!=1)throw(90); GuiShell;\n') + 'wait GUI SHELL OPEN\n'
    script+=testvm.typed('#include "C:/Cursor.cool"\nCursorProbe;\n')+'wait CURSOR SHAPE1\ndelay 100\n'
    # MOVE only, away from all windows; shape stays unchanged.
    script+=testvm.pointer_absolute(700*scale,500*scale,800*scale,600*scale)+'delay 100\n'
    script+=testvm.typed('CursorCheck;\n')+'wait CURSOR CANVAS1\n'
    if ending=='hide':script+=testvm.typed('GuiPointerHide;\n')+'delay 100\n'
    if ending=='exit':
        script+='1 29 1\n1 56 1\n'+testvm.keys_of(16)+'1 56 0\n1 29 0\ndelay 100\n'
        script+=testvm.typed('if(gui_active || gpu.cursor_on) throw(10); Print("CURSOR EXIT%d\\n",1);\n')+'wait CURSOR EXIT1\n'
    script+='delay 300\nquit\n';(d / 'input.txt').write_text(script)
    env=dict(os.environ,COOLVM_CURSOR_DEBUG='1')
    testvm.run_vm(testvm.vm_command(KERNEL,executable=ROOT / ('build/coolvm-venus' if mode=='venus' else 'build/coolvm'),
        no_venus=mode=='cpu',headless=not window,size=(800*scale,600*scale),scale=scale,timeout=80,host_timeout=100,
        disk=disk,input_script=d / 'input.txt',screenshot=d / 'screen.png'),d / 'vm.log',stdin=subprocess.DEVNULL,check=True,env=env)
    log=(d / 'vm.log').read_text(errors='replace')
    assert 'CURSOR CANVAS1' in log and not any(v in log for v in ['ERROR:','Exception:','VENUS FAIL','malformed chain']),log[-2000:]
    if window:
        changes=re.findall(r'NATIVE CURSOR (shape|default) (\d+) ([\d.]+) ([\d.]+) (\d+) (\d+)',log)
        assert any(c[0]=='shape' and int(c[4])==scale and int(c[5])==2*scale for c in changes),changes
        if ending=='exit':assert changes[-1][0]=='default',changes
    elif ending!='exit':
        _,_,rows=testvm.read_png(d / 'screen.png')
        for y in range(490*scale,510*scale):
            for x in range(690*scale,710*scale):
                base=255*((x//scale ^ y//scale)&1);expected=(base,)*3
                sx=x//scale-699;sy=y//scale-498
                if ending=='shape' and 0<=sx<4 and 0<=sy<4:
                    color=SHAPE[sy*4+sx];alpha=color>>24
                    expected=tuple((((color>>b)&255)*alpha+base*(255-alpha)+127)//255 for b in (16,8,0))
                actual=tuple(rows[y][3*x:3*x+3]);assert actual==expected,(name,x,y,actual,expected)
    print(f'gui-cursor-test: {name} PASS',flush=True)


for mode in ['cpu']+(['venus'] if '--venus' in sys.argv else []):
    boot(mode,1);boot(mode,2);boot(mode,1,'hide');boot(mode,1,'exit')
if '--native' in sys.argv:
    boot('cpu',1,'exit',True);boot('venus',2,'exit',True)
print('gui-cursor-test: hardware pointer PASS',flush=True)
