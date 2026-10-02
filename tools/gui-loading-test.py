#!/usr/bin/env python3
"""Input-to-composition latency while the System menu cold-loads Warm apps."""
import argparse
from pathlib import Path
import re
import subprocess
import testvm
from testvm import ROOT

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('kernel')
parser.add_argument('--venus', action='store_true')
parser.add_argument('--output', type=Path, default=ROOT / 'build/gui-loading-test')
parser.add_argument('--input-interval-ms', type=int, default=20,
                    help='input period; 1 ms exercises continuous event backlogs')
parser.add_argument('--loaded', action='store_true',
                    help='enforce the 150 ms maximum under parallel test load; standalone logs it only')
parser.add_argument('--latency-limit-us', type=int, default=150000,
                    help='loaded maximum; use --loaded --latency-limit-us 0 to exercise failure reporting')
args = parser.parse_args()
if args.input_interval_ms < 1 or args.latency_limit_us < 0:
    parser.error('input interval must be positive and latency limit nonnegative')
KERNEL = args.kernel
OUT = args.output
FIXTURE = r'''
CGuiWindow *load_probe;
CTask *load_app;
#define LOAD_LIMIT 150000
#define LOAD_MAX_ENFORCED 0
#define LOAD_INPUT_INTERVAL 20
I64 load_sent, load_handled, load_live, load_max, load_ack_max, load_cursor, load_samples;
I64 load_values[32768];
Bool load_moved, load_overflow;
I64 LoadCmp(I64 a,I64 b) {return (a>b)-(a<b);}
U0 LoadSamples()
{// GuiCompose records the timestamp at completed composition. Reading its
    // ring on core 0 avoids charging this observer's later scheduling to a frame.
    I64 latency;
    if(gui.latency_count-load_cursor>GUI_LATENCY) load_overflow=TRUE;
    while(load_cursor<gui.latency_count) {
        latency=gui.latency[load_cursor++%GUI_LATENCY]*1000000/cnt_freq;
        if(latency>load_max) load_max=latency;
        if(load_samples<32768) load_values[load_samples++]=latency; else load_overflow=TRUE;
    }
}
Bool LoadBusy()
{
    if(!load_app) return FALSE;
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
        Sleep(LOAD_INPUT_INTERVAL);
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
        LoadSamples;
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
            if(latency>load_ack_max) load_ack_max=latency; stamp=0;
        }
        Sleep(1);
    }
}
Bool LoadCheck()
{
    I64 app, deadline, i, compiles, median;
    if(mp_cnt<2) {GuiLog("GUI LOADING needs two cores\n"); return FALSE;}
    ShellExe("warm_kernel_serial = 7351;");
    Spawn(&LoadProbe,NULL,"Loading input probe",0,adam_task);
    while(!load_probe) Sleep(1);
    for(app=0;app<3;app++) {
        load_sent=load_handled=load_live=load_max=load_ack_max=load_samples=compiles=0; load_moved=load_overflow=FALSE;
        load_cursor=gui.latency_count;
        GuiMove(load_probe,540,460);
        GuiFocus(load_probe);
        // The same action dispatcher used by a System-menu selection.
        gui.action=10+app; if(app==2) gui.action=9;
        TaskWake(gui.task);
        load_app=NULL;
        deadline=TimerJiffies+30000;
        while(!load_app && TimerJiffies<deadline) {
            for(i=0;i<GUI_WINDOWS;i++) if(gui.loading[i]) load_app=gui.loading[i];
            Sleep(1);
        }
        if(!load_app) {GuiLog("GUI LOADING launch timeout\n"); return FALSE;}
        Spawn(&LoadInput,NULL,"Loading IRQ source",1,adam_task);
        deadline=TimerJiffies+30000;
        while(LoadBusy && TimerJiffies<deadline) {
            // Concurrent foreground compilation uses the same symbol name as
            // each loader's private Warm compiler. Its value must stay isolated.
            if(ShellExe("warm_kernel_serial + 17;")!=7368) {GuiLog("GUI LOADING compiler isolation failed\n"); return FALSE;}
            compiles++; Sleep(10);
        }
        if(LoadBusy) {GuiLog("GUI LOADING compile timeout\n"); return FALSE;}
        Sleep(60);
        LoadSamples;
        QSortI64(load_values,load_samples,&LoadCmp);
        median=0;
        if(load_samples) median=(load_values[(load_samples-1)/2]+load_values[load_samples/2])/2;
        U8 *s=MStrPrint("GUI LOADING app=%d sent=%d live=%d median=%d us max=%d us handled=%d moved=%d samples=%d compiles=%d ack_max=%d us\n",app,load_sent,load_live,median,load_max,load_handled,load_moved,load_samples,compiles,load_ack_max);GuiLog(s);Free(s);
        if(!load_moved || load_live<5 || load_samples<5 || compiles<5 || load_handled!=load_sent || load_overflow || median>20000 || (LOAD_MAX_ENFORCED && load_max>LOAD_LIMIT)) return FALSE;
        // All app windows are owned by their loader task; close before the next trial.
        for(i=0;i<gui.count;i++) if(gui.windows[i]->owner==load_app) GuiClose(gui.windows[i]);
        Sleep(40);
    }
    return TRUE;
}
U0 LoadCheckSafe()
{
    Bool ok=FALSE;
    try {ok=LoadCheck;} catch {Fs->catch_except=TRUE; GuiLog("GUI LOADING unexpected exception\n");}
    if(ok) GuiLog("GUI LOADING PASS\n"); else GuiLog("GUI LOADING FAILED\n");
    // Both success and failure release the host's wait; errors must not wait
    // 150 seconds for a success-only UART marker.
    GuiLog("GUI LOADING DONE\n");
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
    fixture.write_text(FIXTURE.replace('#define LOAD_LIMIT 150000', f'#define LOAD_LIMIT {args.latency_limit_us}')
                       .replace('#define LOAD_MAX_ENFORCED 0', f'#define LOAD_MAX_ENFORCED {int(args.loaded)}')
                       .replace('#define LOAD_INPUT_INTERVAL 20', f'#define LOAD_INPUT_INTERVAL {args.input_interval_ms}'))
    subprocess.run(['mcopy', '-o', '-i', disk, fixture, '::Loading.cool'], check=True)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n'
    script += testvm.typed('#include "C:/Loading.cool"\nLoadCheckSafe;\n') + 'wait GUI LOADING DONE\nquit\n'
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(KERNEL,
        executable=ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm'),
        no_venus=mode == 'cpu', size=(800, 600), scale=1, timeout=150, host_timeout=170,
        disk=disk, input_script=d / 'input.txt'), d / 'vm.log', stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert not any(s in log for s in ('ERROR:', 'VENUS FAIL', 'Exception:', 'Error:')), log[-3000:]
    samples = re.findall(r'GUI LOADING app=(\d+) sent=(\d+) live=(\d+) median=(\d+) us max=(\d+) us', log)
    assert len(samples) == 3 and 'GUI LOADING PASS' in log, log[-3000:]
    for app, sent, live, median, maximum in samples:
        assert int(live) >= 5 and int(median) <= 20000, samples
        if args.loaded:
            assert int(maximum) <= args.latency_limit_us, samples
        print(f'gui-loading-test: {mode}, app {app}, {live}/{sent} inputs during compilation, median {median} us, max {maximum} us ({"enforced" if args.loaded else "logged only"}) PASS', flush=True)


boot('cpu')
if args.venus:
    boot('venus')
