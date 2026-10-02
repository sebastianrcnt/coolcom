#!/usr/bin/env python3
"""Headless rubber-band resize, preserved frames, and live desktop mode changes."""
import os
import struct
import subprocess
import sys

import testvm
from testvm import ROOT

OUT = ROOT / 'build/gui-resize-test'
KERNEL = sys.argv[1]
FIXTURE = r'''
U0 ResizeSettle() {Sleep(40); while(gui.damage) Sleep(1);}
U0 ResizeShot(I64 n, CGuiWindow *w)
{
    ResizeSettle;
    U8 *path=MStrPrint("C:/R%02d.BMP",n), *msg;
    if(!GuiShot(path)) throw(10); Free(path);
    msg=MStrPrint("RESIZE SHOT %d %d %d %d %d\n",n,w->x,w->y,w->w,w->h); GuiLog(msg); Free(msg);
}
U0 ResizeMouse(I64 x,I64 y,I64 buttons)
{
    GuiMouseInput(x*gui.scale,y*gui.scale,buttons,mouse.wheel); ResizeSettle;
}
U0 ResizeDrag(CGuiWindow *w,I64 shot)
{
    I64 width=w->w,height=w->h,i,seq=w->term->size_seq;
    U32 *pixels=w->pixels,*back=w->back;
    GuiFocus(w); ResizeShot(shot,w);
    ResizeMouse(w->x+width+2*GUI_PAD-5,w->y+height+2*GUI_PAD+GUI_TITLE+GUI_FOOTER-5,1);
    if(gui.drag!=w || !gui.resizing) throw(11);
    for(i=1;i<=4;i++) {
        ResizeMouse(w->x+width+2*GUI_PAD+i*12,w->y+height+2*GUI_PAD+GUI_TITLE+GUI_FOOTER+i*8,1);
        if(w->w!=width || w->h!=height || w->pixels!=pixels || w->back!=back || w->term->size_seq!=seq) throw(12);
    }
    ResizeShot(shot+1,w);
    // The release carries additional motion; only this final size is committed.
    ResizeMouse(w->x+width+2*GUI_PAD+56,w->y+height+2*GUI_PAD+GUI_TITLE+GUI_FOOTER+48,0);
    if(gui.drag || gui.resizing || w->w!=width+56 || w->h!=height+48) throw(13);
    ResizeShot(shot+2,w);
}
U0 ResizePixel(U8 *data)
{
    no_warn data;
    CGuiWindow *w=GuiNewPixel("Resize pixel",320,160); CGuiEvent e; I64 count=0;
    if(!w) throw(14); GuiMove(w,200,120); GuiPointerHide;
    GrRect(0,0,320,160,0xCC2244); GrRect(12,12,48,24,0); GuiPresent; ResizeSettle;
    // An uncommitted white clear must not be carried into either replacement buffer.
    GrRect(0,0,320,160,GUI_WHITE);
    ResizeDrag(w,0);
    Sleep(350); // let the compositor publish repeatedly before the app repaints
    if(w->back[(GUI_TITLE+GUI_PAD+80)*w->scale*w->pw+(1+GUI_PAD+80)*w->scale]!=0xFFCC2244) throw(15);
    while(GuiPoll(&e)) if(e.type==GUI_EVENT_RESIZE) count++;
    if(count!=1) throw(16);
    GuiLog("RESIZE PIXEL PASS\n");
    while(TRUE) Sleep(100);
}
U0 ResizeDesktop(U8 *data)
{
    no_warn data;
    CGuiWindow *w=GuiNew("Resize cells",320,160), *ui; I64 i,seq;
    if(!w) throw(17); GuiMove(w,200,120);
    ConsPutS("\e[48;2;32;64;96m\e[2J\e[HResize cells\e[?25l"); ResizeSettle;
    seq=w->term->size_seq; ResizeDrag(w,3);
    if(w->term->size_seq!=seq+1 || w->term->cells[0].cp!='R') throw(18);
    gui.trace=1; GuiGallery;
    while(gui.focus==w || StrCmp(gui.focus->title,"Gallery")) Sleep(1);
    ui=gui.focus; ResizeSettle; Sleep(200);
    GuiMove(ui,40,GUI_MENU+12); ResizeDrag(ui,6);
    // OS.Ui consumes the resize and produces a frame at the new dimensions.
    Sleep(500);
    ResizeShot(9,ui); GuiLog("RESIZE DESKTOP READY\n");
    I64 widths[5], heights[5];
    widths[0]=1024; widths[1]=648; widths[2]=901; widths[3]=400; widths[4]=905;
    heights[0]=768; heights[1]=496; heights[2]=657; heights[3]=300; heights[4]=665;
    for(i=0;i<5;i++) {
        I64 edge=0; if(i==2) edge=gui.scale-1; // partial logical pixels at a physical 2x edge
        while(fb.w!=widths[i]*gui.scale+edge || fb.h!=heights[i]*gui.scale+edge || gui.w!=widths[i] || gui.h!=heights[i]) Sleep(1);
        ResizeShot(10+i,ui);
        if(ui->x<0 || ui->y<GUI_MENU || ui->x>MaxI64(0,gui.w-ui->w-2*GUI_PAD-3) ||
                ui->y>MaxI64(GUI_MENU,gui.h-ui->h-GUI_TITLE-2*GUI_PAD-GUI_FOOTER-3)) throw(20);
        U8 *msg=MStrPrint("RESIZE DISPLAY %d PASS\n",i); GuiLog(msg); Free(msg);
    }
    GuiLog("RESIZE DESKTOP PASS\n"); while(TRUE) Sleep(100);
}
U0 ResizeLaunch(I64 desktop) {if(desktop) Spawn(&ResizeDesktop,NULL,"Resize desktop",0,adam_task); else Spawn(&ResizePixel,NULL,"Resize pixel",0,adam_task);}
'''


def bmp(path):
    data = path.read_bytes()
    width, height = struct.unpack_from('<ii', data, 18)
    assert height < 0
    return width, -height, data[54:]


def crop(image, x, y, w, h):
    width, _, data = image
    # Ignore alpha: CPU terminal glyphs and app pixels use different alpha conventions.
    return b''.join(data[((y+j)*width+x+i)*4:((y+j)*width+x+i)*4+3]
                    for j in range(h) for i in range(w))


def boot(mode, scale, desktop):
    name = f'{mode}-{scale}x-' + ('desktop' if desktop else 'pixel')
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    frames = d / 'frames'
    frames.mkdir(exist_ok=True)
    for old in frames.glob('*.raw'):
        old.unlink()
    disk = d / 'disk.img'
    testvm.create_disk(disk, 256*1024*1024 if desktop else 64*1024*1024)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    if mode == 'venus':
        subprocess.run([ROOT / 'tools/venus/install.sh', disk], check=True, stdout=subprocess.DEVNULL)
    fixture = d / 'Resize.cool'
    fixture.write_text(FIXTURE)
    subprocess.run(['mcopy', '-o', '-i', disk, fixture, '::Resize.cool'], check=True)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n'
    script += testvm.typed('#include "C:/Resize.cool"\nResizeLaunch(%d);\n' % desktop)
    if desktop:
        script += 'wait RESIZE DESKTOP READY\n'
        for i, (w, h) in enumerate([(1024, 768), (648, 496), (901, 657), (400, 300), (905, 665)]):
            if i == 4:
                # More events arrive while Venus rebuilds. The latest mode must win.
                script += ''.join(f'resize {rw*scale} {rh*scale}\ndelay 1\n'
                                  for rw, rh in [(650, 490), (1100, 750), (700, 510), (1000, 700)] * 3)
            edge = scale-1 if i == 2 else 0
            script += f'resize {w*scale+edge} {h*scale+edge}\nwait RESIZE DISPLAY {i} PASS\n'
        script += 'wait RESIZE DESKTOP PASS\n'
    else:
        script += 'wait RESIZE PIXEL PASS\n'
    script += 'delay 100\nquit\n'
    (d / 'input.txt').write_text(script)
    env = dict(os.environ, COOLVM_FRAMES=str(frames))
    testvm.run_vm(testvm.vm_command(KERNEL,
        executable=ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm'),
        no_venus=mode == 'cpu', size=(800*scale, 600*scale), scale=scale,
        timeout=100, host_timeout=120, disk=disk, input_script=d / 'input.txt',
        screenshot=d / 'screen.png'), d / 'vm.log', env=env, stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert not any(s in log for s in ('ERROR:', 'VENUS FAIL', 'Exception:', 'Error:')), log[-3500:]
    assert f'RESIZE {"DESKTOP" if desktop else "PIXEL"} PASS' in log, log[-3500:]
    assert ('GUI VENUS READY' in log) == (mode == 'venus'), log[-3500:]
    shots = range(3, 15) if desktop else range(3)
    for n in shots:
        subprocess.run(['mcopy', '-o', '-i', disk, f'::R{n:02d}.BMP', d / f'R{n:02d}.BMP'], check=True)
    for first in ([3, 6] if desktop else [0]):
        before, during, after = [bmp(d / f'R{n:02d}.BMP') for n in range(first, first+3)]
        x, y = (204, 145) if first != 6 else (44, 59)
        w, h = (320, 160) if first != 6 else (200, 80)
        reference = crop(before, x*scale, y*scale, w*scale, h*scale)
        assert reference == crop(during, x*scale, y*scale, w*scale, h*scale), f'{name}: content changed during drag {first}'
        assert reference == crop(after, x*scale, y*scale, w*scale, h*scale), f'{name}: content lost on commit {first}'
        # The held screenshot contains a gray rubber band beyond the original window.
        raw = during[2]
        assert raw.count(b'\x80\x80\x80\xff') > 100*scale, f'{name}: no outline'
        if first != 6:
            assert b'\x80\x80\x80\xff' not in after[2], f'{name}: stale outline'
    if desktop:
        assert 'full 0,0,676,528' in log, f'{name}: OS.Ui did not repaint the resized client'
        for n, size in enumerate([(1024, 768), (648, 496), (901, 657), (400, 300), (905, 665)], 10):
            edge = scale-1 if n == 12 else 0
            assert bmp(d / f'R{n:02d}.BMP')[:2] == (size[0]*scale+edge, size[1]*scale+edge)
        w, h, rows = testvm.read_png(d / 'screen.png')
        assert (w, h) == (905*scale, 665*scale)
        px = lambda x, y: bytes(rows[y*scale][x*scale*3:x*scale*3+3])
        assert px(880, 10) == b'\xff'*3 and px(880, 21) == b'\x00'*3, f'{name}: menu width'
        assert px(880, 640) == b'\x00'*3 and px(881, 640) == b'\xff'*3, f'{name}: expanded desktop'
        sizes = [(1024, 768), (648, 496), (901, 657), (400, 300), (905, 665),
                 (650, 490), (1100, 750), (700, 510), (1000, 700)]
        seen = set()
        for path in sorted(frames.glob('*.raw')):
            raw = path.read_bytes()
            matches = [(w, h) for w, h in sizes
                       if len(raw) == (w*scale+(scale-1 if w == 901 else 0))*(h*scale+(scale-1 if w == 901 else 0))*4]
            if not matches:
                assert not seen, f'{name}: fell back to the boot scanout in {path.name}'
                continue  # original boot/GUI resolution
            (w, h), = matches
            stride = w*scale+(scale-1 if w == 901 else 0)
            seen.add((w, h))
            # Each scanout must already contain chrome and the new desktop edge.
            for x in range(8, 28):
                off = (21*scale*stride+x*scale)*4
                assert raw[off:off+3] == b'\x00'*3, f'{name}: incomplete menu in {path.name}'
            off = (21*scale*stride+stride-1)*4
            assert raw[off:off+3] == b'\x00'*3, f'{name}: menu edge in {path.name}'
            if w >= 901:
                for x in range(w-10, w-5):
                    y = h-10
                    off = (y*scale*stride+x*scale)*4
                    assert raw[off:off+3] == bytes([255*((x^y)&1)])*3, f'{name}: incomplete desktop in {path.name}'
        assert set(sizes[:5]) <= seen, (name, seen)
    else:
        reference = crop(bmp(d / 'R00.BMP'), 204*scale, 145*scale, 320*scale, 160*scale)
        observed = 0
        for path in sorted(frames.glob('*.raw')):
            raw = path.read_bytes()
            region = crop((800*scale, 600*scale, raw), 204*scale, 145*scale, 320*scale, 160*scale)
            if not observed and region != reference:
                continue  # before the first completed app frame
            assert region == reference, f'{name}: white/partial frame {path.name}'
            observed += 1
        assert observed >= 6, (name, observed)
    for path in frames.glob('*.raw'):
        path.unlink()
    print(f'gui-resize-test: {name} PASS', flush=True)


for scale in (1, 2):
    for mode in (['cpu', 'venus'] if '--venus' in sys.argv else ['cpu']):
        boot(mode, scale, False)
        boot(mode, scale, True)
