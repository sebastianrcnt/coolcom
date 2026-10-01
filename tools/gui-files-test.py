#!/usr/bin/env python3
"""Files profiling and scroll regression, isolated disk; no compiler changes."""
import argparse
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "warmc"))
from os_modules import os_modules
import json
import re
import subprocess
import testvm
from testvm import ROOT

p = argparse.ArgumentParser()
p.add_argument('kernel')
p.add_argument('--label', default='regression')
p.add_argument('--venus', action='store_true')
p.add_argument('--baseline', action='store_true')
a = p.parse_args()
OUT = ROOT / 'build/gui-files-test' / a.label

# Shadow scalar adapters before WarmRun resolves the foreign functions. Timing
# uses CNTVCT (not ms jiffies); profile reports are outside measurements.
def fixture():
    source = (ROOT / 'os/Warm/OSGuiKernel.cool').read_text()
    names = re.findall(r'(?:I64|U0|CGuiWindow \*)\s*(Wg\w+)\(', source)
    for name in sorted(names, key=len, reverse=True):
        source = re.sub(r'\b' + name + r'\b', 'Original' + name, source)
    wrappers = ''
    for match in re.finditer(r'(I64|U0) (Wg\w+)\(([^)]*)\)', (ROOT / 'os/Warm/OSGuiKernel.cool').read_text()):
        ret, name, params = match.groups()
        if name in ('WgPoll', 'WgPresent'): continue
        args = ','.join(re.findall(r'(\w+)\s*(?:,|$)', params))
        cat = 2 if 'Text' in name or name == 'WgMeasure' else 1
        wrappers += f'{ret} {name}({params}) {{I64 t=ArchCntVct; '
        wrappers += ('I64 r=' if ret == 'I64' else '') + f'Original{name}({args}); I64 elapsed=ArchCntVct-t;prof[{cat}]+=elapsed;if(prof[27])prof[28]+=elapsed; '
        wrappers += ('prof[11]=t;prof[18]=1;' if name=='WgOpen' else '') + ('return r;' if ret == 'I64' else '') + '}\n'
    io = (ROOT / 'os/Warm/OSDirKernel.cool').read_text()
    io = io.replace('WoListPath(', 'OriginalWoListPath(').replace('WoReadPath(', 'OriginalWoReadPath(').replace('WoStat(', 'OriginalWoStat(')
    return '''
U0 WpDone() {prof[20]=1;}
U0 WpFirst(I64 first,I64 total) {prof[15]=first;prof[22]=total;prof[10]=1;}
U0 WpBegin(I64 category) {prof[8+category]=ArchCntVct;if(category==0)prof[27]++;}
U0 WpEnd(I64 category) {prof[4+category]+=ArchCntVct-prof[8+category];if(category==0)prof[27]--;}
''' + source + wrappers + io + '''
I64 WoStat(U8 *path) {I64 t=ArchCntVct;I64 r=OriginalWoStat(path);prof[3]+=ArchCntVct-t;return r;}
WoEntry *WoListPath(U8 *path,I64 *error) {I64 t=ArchCntVct;WoEntry *r=OriginalWoListPath(path,error);prof[3]+=ArchCntVct-t;prof[14]++;return r;}
WkBuffer *WoReadPath(U8 *path) {I64 t=ArchCntVct;WkBuffer *r=OriginalWoReadPath(path);prof[3]+=ArchCntVct-t;return r;}
I64 WgPoll(I64 handle) {I64 r=OriginalWgPoll(handle);prof[12]=ArchCntVct;prof[13]++;return r;}
I64 WgPresent(I64 handle) {Bool explicit=prof[10]!=0;CGuiWindow *w=OriginalWgWindow(handle);if(prof[10] && w->pending){prof[23]=w->dirty_x0;prof[24]=w->dirty_y0;prof[25]=w->dirty_x1;prof[26]=w->dirty_y1;}I64 t=ArchCntVct;I64 r=OriginalWgPresent(handle);if(prof[10]){prof[0]+=ArchCntVct-prof[12];prof[10]=0;prof[19]++;if(prof[18]){prof[17]=ArchCntVct-prof[11];prof[18]=0;}}if(explicit)prof[7]+=ArchCntVct-t;return r;}
'''

def monitor():
    return r'''I64 prof[32];
U0 ProfileApp(U8 *data) {
    CVTerm *v=VtNew(80,24); VtBind(Fs,v);v->owner=Fs;v->sink=&GuiShellSink;VtRelease(v);ShellTask(0);
    U8 *s=MStrPrint("I64 *prof=0x%X;\n#include \"C:/ProfileAdapter.cool\"\n#include \"C:/Files.cool\"\n",data);ShellExe(s);Free(s);
}
U0 ProfileReset() {I64 first=prof[15],total=prof[22];MemSet(prof,0,32*sizeof(I64));prof[15]=first;prof[22]=total;prof[21]=gui.compose_ticks;}
U0 ProfileReport(I64 id,I64 elapsed) {I64 total=prof[0]+prof[5];if(id==0)total=prof[17];U8 *s=MStrPrint("PROFILE %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",id,elapsed,cnt_freq,total,prof[1],prof[2],prof[3],prof[4],prof[5],prof[7],prof[14],gui.compose_ticks-prof[21],prof[19],prof[28]);GuiLog(s);Free(s);}
CGuiWindow *FilesWindow() {I64 i;for(i=0;i<gui.count;i++)if(gui.windows[i]->pixel)return gui.windows[i];return NULL;}
U0 FilesMouse(CGuiWindow *w,I64 x,I64 y,I64 buttons,I64 wheel) {CGuiEvent e;MemSet(&e,0,sizeof(e));e.type=GUI_EVENT_MOUSE;e.x=x;e.y=y;e.buttons=buttons;e.wheel=wheel;GuiEventPush(w,&e);}
U0 FilesWait(CGuiWindow *w,I64 revision) {I64 dl=TimerJiffies+10000;while((w->revision<=revision || !prof[19]) && TimerJiffies<dl)Sleep(1);if(w->revision<=revision || !prof[19])throw(91);while(w->presented<w->revision)Sleep(1);}
U0 FilesBarrier(CGuiWindow *w) {CGuiEvent e;MemSet(&e,0,sizeof(e));e.type=GUI_EVENT_KEY;e.key=1234567;GuiEventPush(w,&e);I64 dl=TimerJiffies+10000;while(!prof[20] && TimerJiffies<dl)Sleep(1);if(!prof[20])throw(92);while(w->presented<w->revision)Sleep(1);}
U0 FilesCold() {I64 t=ArchCntVct;CGuiWindow *w;GuiFiles;while(!(w=FilesWindow))Sleep(1);while(w->revision<2)Sleep(1);while(w->presented<w->revision)Sleep(1);U8 *s=MStrPrint("COLD %d %d\n",ArchCntVct-t,cnt_freq);GuiLog(s);Free(s);GuiClose(w);while(FilesWindow)Sleep(1);}
U0 FilesProfile() {
    I64 t=ArchCntVct,rev,i;CGuiWindow *w;
    ProfileReset; Spawn(&ProfileApp,prof,"Files profile",0,adam_task,SHELL_STACK);while(!(w=FilesWindow))Sleep(1);
    FilesWait(w,0);FilesBarrier(w);ProfileReport(0,ArchCntVct-t);
    ProfileReset;rev=w->revision;t=ArchCntVct;FilesMouse(w,40,100,0,-1);FilesBarrier(w);if(prof[15]!=1)throw(93);ProfileReport(1,ArchCntVct-t);
    ProfileReset;rev=w->revision;t=ArchCntVct;
    for(i=0;i<100;i++)FilesMouse(w,40,100,0,-1);
    FilesBarrier(w);if(prof[15]!=101)throw(94);ProfileReport(2,ArchCntVct-t);
    ProfileReset;rev=w->revision;t=ArchCntVct;FilesMouse(w,40,100,1,0);FilesMouse(w,40,100,0,0);FilesBarrier(w);ProfileReport(3,ArchCntVct-t);
    ProfileReset;rev=w->revision;t=ArchCntVct;FilesMouse(w,80,42,1,0);FilesMouse(w,80,42,0,0);FilesBarrier(w);ProfileReset; t=ArchCntVct;
    rev=w->revision;CGuiEvent e;MemSet(&e,0,sizeof(e));e.type=GUI_EVENT_KEY;e.key='K';GuiEventPush(w,&e);FilesBarrier(w);ProfileReport(4,ArchCntVct-t);
    // Finish the Kernel filter, select its directory, and measure Open/Up.
    U8 *keys="ernel";CGuiEvent k;MemSet(&k,0,sizeof(k));k.type=GUI_EVENT_KEY;
    for(i=0;keys[i];i++){k.key=keys[i];GuiEventPush(w,&k);}prof[20]=0;FilesBarrier(w);
    FilesMouse(w,40,90,1,0);FilesMouse(w,40,90,0,0);prof[20]=0;FilesBarrier(w);
    ProfileReset;t=ArchCntVct;FilesMouse(w,340,42,1,0);FilesMouse(w,340,42,0,0);FilesBarrier(w);ProfileReport(5,ArchCntVct-t);
    ProfileReset;t=ArchCntVct;FilesMouse(w,430,42,1,0);FilesMouse(w,430,42,0,0);FilesBarrier(w);ProfileReport(6,ArchCntVct-t);
    // Pixel-equivalent thumb mapping, including a large held-motion backlog.
    ProfileReset;t=ArchCntVct;FilesMouse(w,248,110,1,0);
    for(i=0;i<32;i++)FilesMouse(w,248,110+i*150/31,1,0);
    FilesMouse(w,248,260,0,0);FilesBarrier(w);
    if(prof[15]!=(260-78-23)*(prof[22]-11)/(222-46))throw(95);
    ProfileReport(7,ArchCntVct-t);
    // Opposite wheel signs must remain ordered at a clamp boundary.
    ProfileReset;t=ArchCntVct;FilesMouse(w,40,100,0,-1000);FilesMouse(w,40,100,0,20);FilesBarrier(w);
    if(prof[15]!=prof[22]-11-20)throw(96);ProfileReport(8,ArchCntVct-t);
    // File IO and preview (independent from directory navigation).
    FilesMouse(w,80,42,1,0);FilesMouse(w,80,42,0,0);prof[20]=0;FilesBarrier(w);
    keys="item000.txt";
    for(i=0;keys[i];i++){k.key=keys[i];GuiEventPush(w,&k);}prof[20]=0;FilesBarrier(w);
    FilesMouse(w,40,90,1,0);FilesMouse(w,40,90,0,0);prof[20]=0;FilesBarrier(w);
    ProfileReset;t=ArchCntVct;FilesMouse(w,340,42,1,0);FilesMouse(w,340,42,0,0);FilesBarrier(w);ProfileReport(9,ArchCntVct-t);
    GuiLog("FILES PROFILE PASS\n");
}
'''

# Measure widget bodies inclusively. Gr counters are subtracted during reporting.
def profile_gui():
    source = (subprocess.check_output(['git','show','f289d91:warmc/standard/src/OS/Gui.warm'],cwd=ROOT,text=True) if a.baseline else (ROOT / 'warmc/standard/src/OS/Gui.warm').read_text())
    decl = '''    pragma Foreign_Import(External_Name => "WpBegin");
    private function profileBegin(category: Int64): Unit is end;
    pragma Foreign_Import(External_Name => "WpEnd");
    private function profileEnd(category: Int64): Unit is end;
'''
    source = source.replace('module body OS.Gui is', 'module body OS.Gui is\n' + decl)
    for name in ['textInput', 'button', 'listFrame', 'listItem', 'poll']:
        pattern = r'(    (?:generic \[R: Region\]\n    )?)function ' + name + r'\((.*?)\): (.*?) is'
        match = re.search(pattern, source)
        prefix, params, ret = match.groups()
        args = []
        for param in params.split(', '):
            if ': ' not in param: continue
            n, typ = param.split(': ', 1)
            args.append(('&~' if typ.startswith('&!') else '') + n)
        category=1 if name=='poll' else 0
        wrapper = prefix + f'function {name}({params}): {ret} is\n        profileBegin({category}); let result: {ret} := profiled{name}(' + ', '.join(args) + f'); profileEnd({category}); return result; end;\n'
        source = source[:match.start()] + wrapper + source[match.start():]
        # Only rename the actual implementation, after the newly inserted wrapper.
        pos = match.start() + len(wrapper)
        source = source[:pos] + source[pos:].replace('function '+name+'(', 'private function profiled'+name+'(', 1)
    return source

for mode in (['cpu', 'venus'] if a.venus else ['cpu']):
    d = OUT / mode
    d.mkdir(parents=True, exist_ok=True)
    disk = d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    cold_package=(ROOT/'build/warmcool/Kernel.cool').read_text()
    cold_start=cold_package.index('Bool WarmCompile(')
    cold_prefix=cold_package[:cold_start];cold_package=cold_package[cold_start:]
    cold_package=cold_package.replace('    CWUnit *u = WNew();', '    I64 cp=ArchCntVct,ct,ce; CWUnit *u = WNew();')
    cold_package=cold_package.replace('    if (!u->error_kind) WBuiltins(u);', '    ct=ArchCntVct; if (!u->error_kind) WBuiltins(u);')
    cold_package=cold_package.replace('    if (!u->error_kind) WLinearity(u);', '    if (!u->error_kind) WLinearity(u); ce=ArchCntVct;')
    cold_package=cold_package.replace('        code = WEmit(u, entry, runtime, FALSE);', '        code = WEmit(u, entry, runtime, FALSE); U8 *timing=MStrPrint("COLD COMPILE %d %d %d %d\\n",ct-cp,ce-ct,ArchCntVct-ce,cnt_freq);GuiLog(timing);Free(timing);')
    (d/'ColdKernel.cool').write_text(cold_prefix+cold_package)
    subprocess.run(['mcopy','-o','-i',disk,d/'ColdKernel.cool','::Warm/Warm.cool'],check=True)
    # A long directory makes traversal cost visible; root includes fixture dirs.
    for start in range(0, 160, 40):
        files = []
        for i in range(start, start+40):
            path = d / f'item{i:03}.txt'; path.write_text('row\n'); files.append(path)
        subprocess.run(['mcopy', '-o', '-i', disk, *files, '::'], check=True)
    probe=monitor()
    if not a.baseline:
        probe=probe.replace('ProfileReport(1,', 'if(prof[14] || prof[23]!=12 || prof[24]!=78 || prof[25]!=256 || prof[26]!=300)throw(97);ProfileReport(1,')
        probe=probe.replace('ProfileReport(2,', 'if(prof[19]!=1 || prof[14])throw(98);ProfileReport(2,')
    if a.baseline: probe=probe.replace('(260-78-23)*(prof[22]-11)/(222-46)', '(260-78-16)*(prof[22]-11)/(222-32)')
    (d / 'Profile.cool').write_text(probe)
    (d / 'ProfileAdapter.cool').write_text(''.join((ROOT / ('os/Warm' if 'Kernel' in n else 'warmc') / n).read_text() for n in ['OSKernel.cool','OSCommon.cool','OSNetCommon.cool','OSNetKernel.cool','OSTaskKernel.cool']) + fixture())
    (d / 'Gui.warm').write_text(profile_gui())
    (d / 'Gui.warmh').write_text((ROOT / 'warmc/standard/src/OS/Gui.warmh').read_text())
    app = (subprocess.check_output(['git','show','f289d91:warmc/examples/gui/Files.warm'],cwd=ROOT,text=True) if a.baseline else (ROOT / 'warmc/examples/gui/Files.warm').read_text())
    app = app.replace('module body GuiFiles is', 'module body GuiFiles is\n    pragma Foreign_Import(External_Name => \"WpFirst\");\n    private function profileFirst(first: Int64, total: Int64): Unit is end;\n    pragma Foreign_Import(External_Name => \"WpDone\");\n    private function profileDone(): Unit is end;')
    barrier = 'case e of when Key(code as code: Int64) do if code = 1234567 then profileDone(); end if; when Idle do skip; when Mouse(x as x: Int64, y as y: Int64, buttons as buttons: Int64, wheel as wheel: Int64) do skip; when Resize(width as width: Int64, height as height: Int64) do skip; when Close do skip; when Menu(id as id: Int64) do skip; end case;'
    if a.baseline: app = app.replace('end if; sleep(&tasks, 10);', 'end if; ' + barrier + ' sleep(&tasks, 10);')
    else: app = app.replace('end if; case e of when Idle', 'end if; ' + barrier + ' case e of when Idle')
    app = app.replace('present(&!w);', 'profileFirst(rows.first, total); present(&!w);')
    (d/'Files.warm').write_text(app)
    modules=[pair for pair in os_modules(ROOT) if '/OS/Gui.' not in pair]
    subprocess.run([ROOT/'tools/warm','compile',*modules,str(d/'Gui.warmh')+','+str(d/'Gui.warm'),str(ROOT/'warmc/examples/gui/Support.warmh')+','+str(ROOT/'warmc/examples/gui/Support.warm'),d/'Files.warm','--entrypoint=GuiFiles:main','--output='+str(d/'Files.cool')],check=True)
    subprocess.run(['mcopy','-o','-i',disk,d / 'Profile.cool','::Profile.cool'], check=True)
    if a.baseline:
        subprocess.run(['mdel','-i',disk,'::GuiFilesModules.txt'],check=True)
        (d/'OriginalGui.warm').write_text(subprocess.check_output(['git','show','f289d91:warmc/standard/src/OS/Gui.warm'],cwd=ROOT,text=True))
        subprocess.run(['mcopy','-o','-i',disk,d/'OriginalGui.warm','::Warm/Standard/OS/Gui.warm'],check=True)
        (d/'OriginalFiles.warm').write_text(subprocess.check_output(['git','show','f289d91:warmc/examples/gui/Files.warm'],cwd=ROOT,text=True))
        subprocess.run(['mcopy','-o','-i',disk,d/'OriginalFiles.warm','::Warm/Examples/gui/Files.warm'],check=True)
    subprocess.run(['mcopy','-o','-i',disk,d / 'ProfileAdapter.cool',d / 'Files.cool','::'],check=True)
    if mode == 'venus': subprocess.run([ROOT/'tools/venus/install.sh',disk], check=True, stdout=subprocess.DEVNULL)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n'
    script += testvm.typed('#include "C:/Profile.cool"\nFilesCold; FilesProfile;\n') + 'wait FILES PROFILE PASS\nquit\n'
    (d / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(a.kernel, executable=ROOT/('build/coolvm-venus' if mode=='venus' else 'build/coolvm'), no_venus=mode=='cpu', size=(800,600), scale=1, timeout=180, host_timeout=200, disk=disk, input_script=d/'input.txt', screenshot=d/'screen.png'),d/'vm.log',stdin=subprocess.DEVNULL,check=True)
    log = (d/'vm.log').read_text(errors='replace')
    assert 'GUI FILES DIRECTORY' in log and 'GUI FILES PREVIEW' in log, log[-4000:]
    assert not any(s in log for s in ('ERROR:', 'Exception:', 'Error:', 'VENUS FAIL')), log[-4000:]
    cold=re.search(r'COLD (\d+) (\d+)',log)
    assert cold, log[-4000:]
    print(f"{mode} cold GuiFiles launch: {int(cold[1])/int(cold[2])*1000:.3f} ms",flush=True)
    compile_timing=re.search(r'COLD COMPILE (\d+) (\d+) (\d+) (\d+)',log)
    assert compile_timing, log[-4000:]
    stages=[int(compile_timing[i])/int(compile_timing[4])*1000 for i in (1,2,3)]
    print(f"{mode} cold compile parse/IO, checking, emission ms: {stages}",flush=True)
    (d/'cold.json').write_text(json.dumps(dict(launch_ms=int(cold[1])/int(cold[2])*1000,parse_ms=stages[0],check_ms=stages[1],emit_ms=stages[2]),indent=2)+'\n')
    rows=[]
    for m in re.finditer(r'PROFILE ([\d ]+)',log):
        id,elapsed,freq,total,rect,text,io,widget,poll,present,lists,compose,paints,widget_gr = map(int,m[1].split())
        row=dict(mode=mode,id=id,wall_ms=elapsed/freq*1000,app_present_ms=total/freq*1000,gr_ms=rect/freq*1000,text_ms=text/freq*1000,io_ms=io/freq*1000,widgets_ms=(widget-widget_gr)/freq*1000,present_ms=present/freq*1000,compose_ms=compose/freq*1000,poll_ms=poll/freq*1000,lists=lists,paints=paints)
        rows.append(row); print(json.dumps(row),flush=True)
    assert len(rows)==10, log[-4000:]
    if not a.baseline:
        for row in rows[1:]:
            # Disk reads can be descheduled by parallel VM/build jobs. Keep
            # the 16 ms processing / 50 ms dispatch bound strict for cached
            # input, and bound Warm work separately from measured IO on load.
            assert row['app_present_ms'] - row['io_ms'] <= 16, row
            assert row['wall_ms'] <= (50 if row['id'] in (1,2,3,4,7,8) else 1000), row
        assert all(row['lists']==0 for row in rows if row['id'] in (1,2,3,4,7,8)), rows
    (d/'results.json').write_text(json.dumps(rows,indent=2)+'\n')
