#!/usr/bin/env python3
"""Example redraws follow widget state changes rather than pointer traffic."""
import subprocess
import sys
import testvm
from testvm import ROOT

KERNEL = sys.argv[1]
OUT = ROOT / 'build/gui-redraw-test'
FIXTURE = r'''
CGuiWindow *RedrawWindow()
{
    I64 i; for(i=0;i<gui.count;i++) if(gui.windows[i]->pixel) return gui.windows[i]; return NULL;
}
Bool RedrawPainted(CGuiWindow *w)
{
    I64 x,y,ink=0;
    for(y=0;y<w->h*w->scale;y++) for(x=0;x<w->w*w->scale;x++)
        if(!(w->pixels[(y+(GUI_TITLE+GUI_PAD)*w->scale)*w->pw+x+(1+GUI_PAD)*w->scale]&0xFFFFFF)) ink++;
    return ink>100;
}
U0 RedrawMouse(CGuiWindow *w, I64 x, I64 y, I64 buttons)
{
    CGuiEvent e; MemSet(&e,0,sizeof(e)); e.type=GUI_EVENT_MOUSE; e.x=x; e.y=y; e.buttons=buttons;
    GuiEventPush(w,&e);
}
U0 RedrawCheck(I64 app)
{
    CGuiWindow *w; I64 revision, i, deadline, x=20, y=48;
    if(app==0) GuiFiles; else if(app==1) GuiTop; else if(app==2) GuiSettings; else GuiWidgets;
    while(!(w=RedrawWindow)) Sleep(1);
    while(!RedrawPainted(w)) Sleep(1);
    Sleep(20); revision=w->revision;
    for(i=0;i<32;i++) RedrawMouse(w, 24+i*2, 24+i, 0);
    Sleep(60);
    if(w->revision!=revision || w->pending) throw(20+app);
    // A button (Files: Reload, Top: Refresh), the selected 1x radio in Settings, a Widgets button.
    if(app==0) {x=184;y=20;} else if(app==1) {x=48;y=320;} else if(app==2) {x=114;y=40;} else {x=220;y=44;}
    RedrawMouse(w,x,y,1); deadline=TimerJiffies+500;
    while(w->revision<=revision && TimerJiffies<deadline) Sleep(1);
    if(w->revision<=revision) throw(30+app);
    revision=w->revision;
    for(i=0;i<16;i++) RedrawMouse(w,x+i%4,y+i%4,1);
    Sleep(60);
    if(w->revision!=revision || w->pending) throw(40+app);
    RedrawMouse(w,x,y,0); deadline=TimerJiffies+500;
    while(w->revision<=revision && TimerJiffies<deadline) Sleep(1);
    if(w->revision<=revision) throw(50+app);
    GuiClose(w); while(RedrawWindow) Sleep(1);
    U8 *message=MStrPrint("REDRAW%d PASS\n",app);GuiLog(message);Free(message);
}
U0 RedrawAll() {I64 i; for(i=0;i<4;i++) RedrawCheck(i);}
'''


def boot(mode):
    d = OUT / mode
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    if mode == 'venus':
        subprocess.run([ROOT / 'tools/venus/install.sh', disk], check=True, stdout=subprocess.DEVNULL)
    fixture = d / 'Redraw.cool'
    fixture.write_text(FIXTURE)
    subprocess.run(['mcopy', '-o', '-i', disk, fixture, '::Redraw.cool'], check=True)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n' + testvm.typed('if(gui.count!=1)throw(90); GuiShell;\n') + 'wait GUI SHELL OPEN\n'
    script += testvm.typed('#include "C:/Redraw.cool"\nRedrawAll;\n')
    script += ''.join(f'wait REDRAW{i} PASS\n' for i in range(4)) + 'quit\n'
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(KERNEL,
        executable=ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm'),
        no_venus=mode == 'cpu', size=(800, 600), scale=1,
        timeout=100, host_timeout=120, disk=disk, input_script=d / 'input.txt'),
        d / 'vm.log', stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert not any(s in log for s in ('ERROR:', 'VENUS FAIL', 'Exception:', 'Error:')), log[-3000:]
    assert all(f'REDRAW{i} PASS' in log for i in range(4)), log[-3000:]
    print(f'gui-redraw-test: {mode}, Files/Top/Settings/Widgets passive motion, press/hold/release PASS', flush=True)


boot('cpu')
if '--venus' in sys.argv:
    boot('venus')
