#!/usr/bin/env python3
"""Desktop file/monitor/settings workflows with the shared testvm runner."""
import subprocess
import sys
import testvm
from testvm import ROOT
KERNEL = sys.argv[1]
OUT = ROOT / 'build/gui-apps-test'

def boot(mode):
    d = OUT / mode
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    (d / 'GuiFixture.txt').write_text('Visible file preview\nSecond line\n')
    subprocess.run(['mcopy','-o','-i',disk,d / 'GuiFixture.txt','::GuiFixture.txt'],check=True)
    if mode == 'venus':
        subprocess.run([ROOT / 'tools/venus/install.sh',disk],check=True,stdout=subprocess.DEVNULL)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n' + testvm.typed('if(gui.count!=1)throw(90); GuiShell;\n') + 'wait GUI SHELL OPEN\n'
    def click(x,y):
        return testvm.pointer_absolute(x,y,800,600) + 'delay 40\n1 272 1\ndelay 40\n1 272 0\ndelay 40\n'
    script += testvm.typed('GuiTop;\n') + 'wait GUI TOP READY\n'
    # Window 2's client starts at (72,107). Select the first task (Adam), Kill, confirm with Return.
    script += click(140,170) + 'wait GUI TOP SELECTED\n' + click(552,427) + 'delay 200\n' + testvm.keys_of(28) + 'wait GUI TOP KILL DENIED\n'
    script += click(78,92) + 'wait GUI TOP CLOSED\n'
    script += testvm.typed('GuiSettings;\n') + 'wait GUI SETTINGS READY\n'
    # The 2x radio; at 2x the 1x radio's logical (186,147) is (372,294) in pointer pixels.
    script += click(146,167) + 'wait GUI SETTINGS SCALE2\nwait GUI SCALE APPLIED\n'
    script += click(372,294) + 'wait GUI SETTINGS SCALE1\nwait GUI SCALE APPLIED\n'
    script += click(166,223) + 'wait GUI SETTINGS BITMAP\n'
    script += click(78,92) + 'wait GUI SETTINGS CLOSED\n'
    script += testvm.typed('GuiFiles;\n') + 'wait GUI FILES PAINTED\n'
    # Navigate into Kernel, then back to the root through the app's Dir capability:
    # the filter field (553,127), the first row (140,186), Open (180,127), Up (108,127).
    script += click(553,127) + testvm.typed('Kernel') + 'wait GUI FILES FILTER\n'
    script += 'delay 100\n' + click(140,186) + 'wait GUI FILES SELECTED\n'
    script += click(180,127) + 'wait GUI FILES DIRECTORY\nwait GUI FILES LOADED\n'
    script += click(108,127) + 'wait GUI FILES UP\nwait GUI FILES LOADED\n'
    script += click(553,127) + testvm.typed('GuiFixture.txt') + 'wait GUI FILES FILTER\n'
    script += 'delay 100\n' + click(140,186) + 'wait GUI FILES SELECTED\n'
    script += click(180,127) + 'wait GUI FILES PREVIEW\n'
    # A later mouse event must preserve the preview.
    script += click(560,430) + 'delay 100\nquit\n'
    (d / 'input.txt').write_text(script)
    vm = ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm')
    testvm.run_vm(testvm.vm_command(KERNEL,executable=vm,no_venus=mode=='cpu',size=(800,600),scale=1,
        timeout=110,host_timeout=130,disk=disk,input_script=d / 'input.txt',screenshot=d / 'screen.png'),
        d / 'vm.log',stdin=subprocess.DEVNULL,check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert not any(s in log for s in ['ERROR:','VENUS FAIL','Error:','Exception:']),log[-3000:]
    assert 'GUI FILES PREVIEW' in log and 'GUI TOP KILL DENIED' in log,log[-3000:]
    w,h,rows=testvm.read_png(d / 'screen.png')
    pixel=lambda x,y: tuple(rows[y][3*x:3*x+3])
    assert pixel(69,150)==(255,255,255),'file window inset'
    assert any(pixel(x,y)==(0,0,0) for y in range(158,175) for x in range(400,600)), 'file preview visible'
    assert pixel(225,186)==(0,0,0),'file selection inversion'
    print(f'gui-apps-test: {mode}, task monitor, scale changes, directory navigation, preview PASS',flush=True)
    return w,h,rows

cpu=boot('cpu')
if '--venus' in sys.argv:
    gpu=boot('venus')
    for y in range(82,460):
        assert cpu[2][y][68*3:597*3]==gpu[2][y][68*3:597*3],f'app CPU/Venus mismatch row {y}'
print('gui-apps-test: G4 applications PASS',flush=True)
