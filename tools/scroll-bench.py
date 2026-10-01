#!/usr/bin/env python3
"""Repeatable coolvm scroll timings and screenshots; artifacts under build/scroll-bench."""
import argparse
import ctypes
import struct
import json
import pathlib
import re
import resource
import subprocess

import testvm
from testvm import ROOT

ROOT = pathlib.Path(__file__).resolve().parent.parent
p = argparse.ArgumentParser()
p.add_argument('label')
p.add_argument('image')
p.add_argument('--vm', default='build/coolvm')
p.add_argument('--size', action='append', help='WIDTHxHEIGHT; repeat to override default resolutions')
p.add_argument('--lines', type=int, default=3000)
p.add_argument('--disk', help='disk containing the resident Vulkan terminal app')
p.add_argument('--expect-venus', type=int, choices=[0,1])
p.add_argument('--timeout', type=int, default=60)
p.add_argument('--expect-gpu', type=int, choices=[0, 1])
p.add_argument('--expect-scanout', type=int, choices=[0, 1])
p.add_argument('--repeat', type=int, default=3)
p.add_argument('--extra', action='append', default=[])
p.add_argument('--compare', help='compare decoded final pixels against this label')
a = p.parse_args()
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
timebase = (ctypes.c_uint32 * 2)()
ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(timebase))
def cpu_ns(pid):
    buf = ctypes.create_string_buffer(1024)
    if libproc.proc_pid_rusage(pid, 0, ctypes.byref(buf)):
        raise OSError('proc_pid_rusage failed')
    user, system = struct.unpack_from('QQ', buf.raw, 16)
    return (user + system) * timebase[0] / timebase[1]

results = []
sizes = [tuple(map(int, size.split('x'))) for size in a.size] if a.size else [(1024, 768), (3200, 2000), (1031, 775)]
for width, height in sizes:
    for trial in range(a.repeat):
        d = ROOT / 'build/scroll-bench' / f'{a.label}-{width}-{height}-{trial}'
        d.mkdir(parents=True, exist_ok=True)
        # Counter covers output and forced render separately; normal timer stays active.
        forced = ('I64 i,t,e,r=0,q; ConsClear; FbFlush; Print("START%d\\n",1); t=ArchCntVct; '
                  'for(i=0;i<3000;i++){Print("row %04d abcdefghijklmnopqrstuvwxyz\\n",i);'
                  'q=ArchCntVct; FbFlush; r+=ArchCntVct-q;} e=ArchCntVct-t; '
                  'Print("MEASURE%d %d %d %d\\n",1,e,r,cnt_freq);')
        if a.expect_venus == 1:
            forced = forced.replace('t=ArchCntVct;', 'I64 sf=fb.venus_frames,sc=fb.venus_completed,sr=fb.venus_records,su=fb.venus_uploads; t=ArchCntVct;')
            forced += 'Print("SUBMITTED%d %d %d %d %d\\n",1,fb.venus_frames-sf,fb.venus_completed-sc,fb.venus_records-sr,fb.venus_uploads-su);'
        burst = ('Print("START%d\\n",2); t=ArchCntVct; '
                 'for(i=0;i<3000;i++)Print("burst %04d abcdefghijklmnopqrstuvwxyz\\n",i); '
                 'FbFlush; e=ArchCntVct-t; Print("BURST%d %d %d\\n",1,e,cnt_freq);')
        pixels = ('ConsClear; FbFlush; for(i=0;i<fb.rows*3+7;i++){'
                  'Print("pixel %04d abcdefghijklmnopqrstuvwxyz\\n",i); FbFlush;} '
                  'FbFillRect(13,17,21,35,0x123456); FbCursorHide; FbFlush; FbFinish; UartPutS("PIXEL "); UartPutS("DONE\\n");')
        forced = forced.replace('3000', str(a.lines))
        burst = burst.replace('3000', str(a.lines))
        probe = ''
        if a.expect_scanout is not None:
            probe = testvm.typed('Print("SCAN%d %d\\n",1,fb.scanout!=NULL);\n') + 'wait SCAN1 \n'
        if a.expect_gpu is not None:
            probe += testvm.typed('Print("GPU%d %d\\n",1,fb.gpu);\n') + 'wait GPU1 \n'
        if a.expect_venus is not None:
            probe += testvm.typed('Print("VENUS%d %d\\n",1,fb.venus);\n') + 'wait VENUS1 \n'
        script = (testvm.BOOT + probe + testvm.typed(forced+'\n') + 'wait MEASURE1 \n' +
                  testvm.typed(burst+'\n') + 'wait BURST1 \n' + testvm.typed(pixels+'\n') +
                  'wait PIXEL DONE\nwait > \ndelay 200\nquit\n')
        (d/'input.txt').write_text(script)
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        phase_cpu = {}
        with (d/'vm.log').open('wb') as out:
            proc = subprocess.Popen([a.vm,'--headless','--cpus','2','--mem','1024','--timeout',str(a.timeout),
                            '--width',str(width),'--height',str(height),'--bootargs','coolcom.scale=1','--input-script',str(d/'input.txt'),
                            '--screenshot',str(d/'screen.png'),*(['--disk',a.disk] if a.disk else []),*a.extra,a.image],
                            stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
            for raw in proc.stdout:
                out.write(raw)
                text = raw.decode(errors='replace').strip()
                if text in ('START1', 'START2') or re.fullmatch(r'(MEASURE1|BURST1) [0-9 ]+', text):
                    phase_cpu[text.split()[0]] = cpu_ns(proc.pid)
            if proc.wait() != 0:
                raise RuntimeError(f'VM failed: {d}/vm.log')
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        log = (d/'vm.log').read_text()
        m = re.search(r'MEASURE1 (\d+) (\d+) (\d+)',log)
        b = re.search(r'BURST1 (\d+) (\d+)',log)
        if not m or not b or 'Exception:' in log:
            raise RuntimeError(f'benchmark failed: {d}/vm.log')
        elapsed, render, freq = map(int,m.groups())
        burst, bf = map(int,b.groups())
        row = dict(label=a.label,width=width,height=height,trial=trial,
                   output_ms=elapsed/freq*1000,render_us=render/freq*1e6/a.lines,
                   burst_ms=burst/bf*1000,host_cpu_s=after.ru_utime+after.ru_stime-before.ru_utime-before.ru_stime)
        if a.expect_venus == 1:
            counts = re.search(r'SUBMITTED1 (\d+) (\d+) (\d+) (\d+)',log)
            if not counts: raise RuntimeError('missing asynchronous counters')
            for key,value in zip(['submitted_frames','completed_frames','recorded_draws','recorded_uploads'], map(int,counts.groups())): row[key]=value
        row['forced_cpu_pct'] = (phase_cpu['MEASURE1']-phase_cpu['START1']) / (elapsed/freq) / 1e7
        row['burst_cpu_pct'] = (phase_cpu['BURST1']-phase_cpu['START2']) / (burst/bf) / 1e7
        if a.expect_scanout is not None:
            scan = re.search(r'SCAN1 ([01])', log)
            expected = a.expect_scanout if width % 8 == 0 and height % 16 == 0 else 0
            assert scan and int(scan[1]) == expected, f'wrong FDT capability selection: {d}'
        if a.expect_gpu is not None:
            mode = re.search(r'GPU1 ([01])', log)
            assert mode and int(mode[1]) == a.expect_gpu, f'wrong GPU selection: {d}'
        if a.expect_venus is not None:
            mode = re.search(r'VENUS1 ([01])',log)
            assert mode and int(mode[1]) == a.expect_venus, f'wrong Vulkan selection: {d}'
        if a.compare:
            reference = ROOT / 'build/scroll-bench' / f'{a.compare}-{width}-{height}-{trial}' / 'screen.png'
            assert testvm.read_png(reference) == testvm.read_png(d/'screen.png'), f'pixels differ: {d}'
        results.append(row)
        print(json.dumps(row),flush=True)
(ROOT/'build/scroll-bench'/f'{a.label}.json').write_text(json.dumps(results,indent=2)+'\n')
