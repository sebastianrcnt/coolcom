#!/usr/bin/env python3
"""Compare editor and compositor key/paint latency with an archived Cool revision in scratch VMs.
Usage: python3 tools/program-perf.py build/kernel.Image BASELINE_REVISION
Results and VM logs are written under build/program-perf; installed programs are untouched.
"""
import json
import re
import subprocess
import sys
from pathlib import Path
import testvm
from testvm import ROOT


def benchmark(kernel, revision, variant):
    out = ROOT / 'build/program-perf' / variant
    out.mkdir(parents=True, exist_ok=True)
    disk = out / 'disk.img'
    testvm.create_disk(disk, 64 * 1024 * 1024, label='PERFTEST', capture_output=True)
    testvm.install_disk_files(disk, capture_output=True)

    def copy(path, name=None):
        subprocess.run(['mcopy', '-o', '-i', str(disk), str(path), '::' + (name or path.name)], check=True)

    if variant == 'cool':
        original = subprocess.check_output(['git', 'show', revision + ':os/Disk/Vim.cool'], cwd=ROOT)
        (out / 'Vim.cool').write_bytes(original)
        copy(out / 'Vim.cool')
        (out / 'Tmux.cool').write_bytes(subprocess.check_output(['git', 'show', revision + ':os/Disk/Tmux.cool'], cwd=ROOT))
        copy(out / 'Tmux.cool')
        init = (ROOT / 'os/Disk/Init.cool').read_text().replace('#include "C:/WarmPrograms.cool"', '#include "C:/Vim.cool"\n#include "C:/Tmux.cool"')
        (out / 'Init.cool').write_text(init)
        copy(out / 'Init.cool')
    (out / 'Bench.txt').write_text('abc def ghi\n' * 500)
    copy(out / 'Bench.txt')
    (out / 'Big.txt').write_text(''.join(f'line {i:05d}\n' for i in range(30000)))
    copy(out / 'Big.txt')
    if variant == 'cool':
        tm_start = 'tm_session=CAlloc(sizeof(CTmSession)); AnsiTermSize(&tm_session->rows,&tm_session->cols); AnsiAltScreen(TRUE); TmWindowNew; TmSplit(TRUE);'
        tm_key = 'VtKeyPush(tm_session->win[tm_session->current].active->term,KEY_LEFT);'
        tm_paint = 'tm_session->redraw=TRUE; TmRender;'
        tm_end = 'TmClose; TmClose; Free(tm_session); tm_session=NULL; vt_focus=old_focus; AnsiCursorShow; AnsiAltScreen(FALSE);'
    else:
        tm_start = 'tm_session=WtmCreate; WtmPrepare(tm_session); WtmSplit(tm_session,TRUE);'
        tm_key = 'WtmPush(tm_session,KEY_LEFT);'
        tm_paint = 'WtmPaint(tm_session);'
        tm_end = 'WtmClose(tm_session); WtmClose(tm_session); WtmDetach(tm_session); WtmDestroy(tm_session); tm_session=0;'
    runner = '''U0 Perf() {
        I64 i, started, navigation, insertion, paint, big;
        VimOpen("C:/Bench.txt");
        started=ArchCntVct;
        for(i=0;i<2000;i++) VimKey('j');
        navigation=ArchCntVct-started;
        VimKey('i'); started=ArchCntVct;
        for(i=0;i<2000;i++) VimKey('a');
        insertion=ArchCntVct-started; VimKey(KEY_ESC);
        started=ArchCntVct;
        for(i=0;i<50;i++) VimDraw;
        paint=ArchCntVct-started;
        VimKey(':'); VimKey('w'); VimKey(KEY_ENTER); VimClose;
        VimOpen("C:/Big.txt"); started=ArchCntVct;
        VimKey('G'); VimDraw;
        big=ArchCntVct-started; VimClose;
        Print("\\nPERF %d %d %d %d %d\\n",navigation,insertion,paint,big,ArchCntFrq);
        CVTerm *old_focus=vt_focus;
        I64 forwarding, composition;
        TM_START
        Sleep(2000);
        started=ArchCntVct;
        for(i=0;i<2000;i++) {TM_KEY}
        forwarding=ArchCntVct-started;
        Sleep(100);
        started=ArchCntVct;
        for(i=0;i<50;i++) {TM_PAINT}
        composition=ArchCntVct-started;
        TM_END
        if(vt_focus!=old_focus) Print("ERROR: benchmark focus not restored\\n");
        Print("\\nTMPERF %d %d %d\\n",forwarding,composition,ArchCntFrq);
        Print("PERFDONE%d\\n",1); Shutdown;
    }
    Perf;
    '''
    runner = runner.replace('TM_START',tm_start).replace('TM_KEY',tm_key).replace('TM_PAINT',tm_paint).replace('TM_END',tm_end)
    (out / 'Perf.cool').write_text(runner)
    copy(out / 'Perf.cool')
    script = testvm.BOOT + testvm.typed('#include "C:/Perf.cool"\n') + testvm.finish('PERFDONE1')
    (out / 'input.txt').write_text(script)
    testvm.run_vm(testvm.vm_command(kernel, no_venus=True, timeout=30, input_script=out / 'input.txt', disk=disk,
                                   size=(640, 480), host_timeout=35), out / 'vm.log')
    log = (out / 'vm.log').read_text(errors='replace')
    testvm.check_init_log(log)
    found = re.search(r'\nPERF (\d+) (\d+) (\d+) (\d+) (\d+)\n', log)
    assert found and 'PERFDONE1' in log and 'ERROR' not in log, f'benchmark failed: {out}/vm.log'
    edited = subprocess.check_output(['mtype', '-i', str(disk), '::Bench.txt'])
    assert edited.count(b'a') == 2500, f'insertion did not run: {variant}, {edited.count(b"a")}'
    a, b, c, d, frequency = map(int, found.groups())
    tm = re.search(r'\nTMPERF (\d+) (\d+) (\d+)\n', log)
    assert tm, f'compositor benchmark failed: {out}/vm.log'
    keys, paint_ticks, tm_frequency = map(int, tm.groups())
    return dict(tmux_forward_us=keys * 1e6 / tm_frequency / 2000,
                tmux_paint_ms=paint_ticks * 1e3 / tm_frequency / 50,
                navigation_us=a * 1e6 / frequency / 2000, insertion_us=b * 1e6 / frequency / 2000,
                paint_ms=c * 1e3 / frequency / 50, large_scroll_ms=d * 1e3 / frequency)


def main():
    cool = benchmark(sys.argv[1], sys.argv[2], 'cool')
    warm = benchmark(sys.argv[1], sys.argv[2], 'warm')
    report = dict(baseline=sys.argv[2], cool=cool, warm=warm,
                  ratio={name: warm[name] / value for name, value in cool.items()})
    (ROOT / 'build/program-perf/results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
