#!/usr/bin/env python3
"""Input-to-composition latency while the System menu cold-loads Warm apps."""
import re
import subprocess
import sys
import testvm
from testvm import ROOT

KERNEL = sys.argv[1]
OUT = ROOT / 'build/gui-loading-test'
FIXTURE = r'''
CGuiWindow *load_probe;
CTask *load_app;
I64 load_sent, load_handled, load_live, load_max; Bool load_moved;
Bool LoadBusy()
{
    I64 i; for(i=0;i<GUI_WINDOWS;i++) if(gui.loading[i]==load_app) return TRUE; return FALSE;
}
U0 LoadInput(U8 *data)
{
    no_warn data; I64 i=0;
    GuiMouseInput(640,470,1,0); GuiMouseInput(648,470,1,0); GuiMouseInput(648,470,0,0);
    // A second core models real device IRQs arriving while core 0 compiles.
    while(LoadBusy) {
        // Keep keyboard focus on the probe, including the final backlog
        // consumed after the newly loaded app creates its window.
        GuiMouseInput(600+i%32, 550, 1, 0);
        GuiMouseInput(600+i%32, 550, 0, 0); GuiKey('p'); load_sent++; i++;
        Sleep(20);
    }
}
U0 LoadProbe(U8 *data)
{
    no_warn data; CGuiEvent e; I64 revision=0, stamp=0, latency;
    load_probe=GuiNewPixel("Loading input probe",240,120);
    if(!load_probe) throw(1);
    GuiMove(load_probe,540,460);
    GrRect(0,0,240,120,GUI_WHITE); GuiPresent;
    while(TRUE) {
        if(LoadBusy && load_probe->x==548) load_moved=TRUE;
        while(GuiPoll(&e,FALSE)) {
            if(e.type==GUI_EVENT_KEY && e.key=='p') {
                if(!stamp) stamp=e.vct;
                load_handled++; if(LoadBusy) load_live++;
                GrRect(20,20,40,40,(load_handled&1)*0x2266CC);
            }
        }
        if(load_probe->pending) {GuiPresent(TRUE);revision=load_probe->revision;}
        if(stamp && load_probe->presented>=revision) {
            latency=(ArchCntVct-stamp)*1000000/cnt_freq;
            if(latency>load_max) load_max=latency; stamp=0;
        }
        Sleep(1);
    }
}
U0 LoadCheck()
{
    I64 app, deadline, i;
    if(mp_cnt<2) throw(2);
    Spawn(&LoadProbe,NULL,"Loading input probe",0,adam_task);
    while(!load_probe) Sleep(1);
    for(app=0;app<3;app++) {
        load_sent=load_handled=load_live=load_max=0; load_moved=FALSE;
        GuiMove(load_probe,540,460);
        GuiFocus(load_probe);
        // The same action dispatcher used by a System-menu selection.
        gui.action=10+app; if(app==2) gui.action=9;
        TaskWake(gui.task);
        load_app=NULL;
        while(!load_app) {
            for(i=0;i<GUI_WINDOWS;i++) if(gui.loading[i]) load_app=gui.loading[i];
            Sleep(1);
        }
        Spawn(&LoadInput,NULL,"Loading IRQ source",1,adam_task);
        deadline=TimerJiffies+30000;
        while(LoadBusy && TimerJiffies<deadline) Sleep(1);
        if(LoadBusy) throw(3);
        Sleep(60);
        U8 *s=MStrPrint("GUI LOADING app=%d sent=%d live=%d max=%d us handled=%d\n",app,load_sent,load_live,load_max,load_handled);GuiLog(s);Free(s);
        if(!load_moved || load_live<5 || load_handled!=load_sent || load_max>100000) throw(4);
        // All app windows are owned by their loader task; close before the next trial.
        for(i=0;i<gui.count;i++) if(gui.windows[i]->owner==load_app) GuiClose(gui.windows[i]);
        Sleep(40);
    }
    GuiLog("GUI LOADING PASS\n");
}
'''


def boot(mode):
    d = OUT / mode
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    if mode == 'venus':
        subprocess.run([ROOT / 'tools/venus/install.sh', disk], check=True, stdout=subprocess.DEVNULL)
    fixture = d / 'Loading.cool'
    fixture.write_text(FIXTURE)
    subprocess.run(['mcopy', '-o', '-i', disk, fixture, '::Loading.cool'], check=True)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n'
    script += testvm.typed('#include "C:/Loading.cool"\nLoadCheck;\n') + 'wait GUI LOADING PASS\nquit\n'
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(KERNEL,
        executable=ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm'),
        no_venus=mode == 'cpu', size=(800, 600), scale=1, timeout=150, host_timeout=170,
        disk=disk, input_script=d / 'input.txt'), d / 'vm.log', stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert not any(s in log for s in ('ERROR:', 'VENUS FAIL', 'Exception:', 'Error:')), log[-3000:]
    samples = re.findall(r'GUI LOADING app=(\d+) sent=(\d+) live=(\d+) max=(\d+) us', log)
    assert len(samples) == 3 and 'GUI LOADING PASS' in log, log[-3000:]
    for app, sent, live, maximum in samples:
        assert int(live) >= 5 and int(maximum) <= 100000, samples
        print(f'gui-loading-test: {mode}, app {app}, {live}/{sent} inputs during compilation, max {maximum} us PASS', flush=True)


boot('cpu')
if '--venus' in sys.argv:
    boot('venus')
