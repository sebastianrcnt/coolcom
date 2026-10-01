#!/usr/bin/env python3
"""QEMU virt's standard, reply-free virtio-gpu cursor queue."""
import os
import pathlib
import re
import selectors
import subprocess
import sys
import time
import qemu
import testvm
from testvm import ROOT
D=ROOT / 'build/gui-cursor-qemu-test';D.mkdir(parents=True,exist_ok=True)
disk=D / 'disk.img';testvm.create_disk(disk);testvm.install_disk_files(disk,stdout=subprocess.DEVNULL)
probe=D / 'Cursor.cool'
probe.write_text('''U0 CursorQemu()
{
    U32 shape[4]; I64 before;
    shape[0]=0xFF000000;shape[1]=0xFFFFFFFF;shape[2]=0;shape[3]=0xFFFFFFFF;
    FontSet(NULL);FontScale(1);
    if(!fb.gpu || !Gui) throw(5);
    while(gui.count!=1) Sleep(1);
    GuiShell; while(gui.count!=2) Sleep(1);
    if(!GuiPointerSet(shape,2,2,1,1)) throw(6);
    before=gpu.q[1].last_used; GpuPointerMove(20,30);
    if(gpu.q[1].last_used!=before+1) throw(7);
    GuiPointerHide; if(gpu.cursor_on || !GuiPointerShow) throw(8);
    gui.action=2;while(gui_active || gui.task) Sleep(1);
    if(gpu.cursor_on || !gpu.active) throw(9);
    Print("QEMU CURSOR%d\\n",1);
}
''')
subprocess.run(['mcopy','-o','-i',disk,probe,'::Cursor.cool'],check=True)
cmd=qemu.command(pathlib.Path(sys.argv[1]).resolve(),disk,qemu.accelerator())+['-device','virtio-gpu-device']
with (D / 'serial.log').open('wb') as log:
    p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    sel=selectors.DefaultSelector();sel.register(p.stdout,selectors.EVENT_READ);pending=b''
    def expect(pattern,timeout=60):
        global pending
        deadline=time.monotonic()+timeout
        while True:
            match=re.search(pattern,pending)
            if match:pending=pending[match.end():];return
            if time.monotonic()>=deadline:raise AssertionError(f'QEMU cursor timeout: {pattern}; {D}/serial.log')
            if not sel.select(1):continue
            chunk=os.read(p.stdout.fileno(),65536)
            if not chunk:raise AssertionError(f'QEMU exited: {pattern}; {D}/serial.log')
            pending+=chunk;log.write(chunk);log.flush()
            assert b'Exception:' not in chunk and b'ERROR:' not in chunk,chunk
    def line(text):p.stdin.write((text+'\n').encode());p.stdin.flush()
    try:
        expect(rb'C:/> ');line('#include "C:/Cursor.cool"');expect(rb'C:/> ')
        line('CursorQemu;');expect(rb'\r?\nQEMU CURSOR1\r?\n');expect(rb'C:/> ')
        line('Shutdown;');expect(rb'Power off\.');assert p.wait(timeout=10)==0
    finally:
        sel.close()
        if p.poll() is None:p.terminate();p.wait(timeout=10)
print('gui-cursor-qemu-test: standard UPDATE/MOVE/hide and GUI exit PASS',flush=True)
