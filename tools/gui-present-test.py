#!/usr/bin/env python3
"""Every submitted CPU/Venus frame must contain a completed pixel-app scene."""
import os
import pathlib
import subprocess
import sys

import testvm
from testvm import ROOT

KERNEL = sys.argv[1]
OUT = ROOT / 'build/gui-present-test'
FIXTURE = r'''
U0 PresentScene(I64 color)
{
    GrRect(0, 0, 320, 160, color);
    GrText(12, 12, "Completed frame");
    GrRect(12, 44, 72, 28, 0); GrRect(14, 46, 68, 24, color); GrText(24, 50, "Open");
    GrRect(100, 44, 72, 28, 0); GrRect(102, 46, 68, 24, color); GrText(124, 50, "Up");
}
U0 PresentWait(CGuiWindow *w)
{
    I64 revision = w->revision;
    while(w->presented < revision) Sleep(1);
}
U0 PresentProbe(U8 *data)
{
    no_warn data;
    CGuiWindow *w = GuiNewPixel("Present", 320, 160); CGuiEvent e;
    I64 i, j, color, revision, frames, stride; U32 *p;
    if(!w) throw(1);
    GuiMove(w, 200, 120);
    PresentScene(0xCC2244); if(!GuiPresent) throw(2); PresentWait(w);
    GuiLog("PRESENT READY\n");
    for(i=0; i<6; i++) {
        revision = w->revision; frames = gui.frames;
        GrRect(-8, -8, 336, 176, GUI_WHITE);
        // Force unrelated desktop/chrome damage while the app is half-painted.
        // Sleep yields to the compositor; no poll/present is allowed here.
        for(j=0; j<8; j++) {GuiWinDamage(w); Sleep(16);}
        if(w->revision != revision || gui.frames < frames+4) throw(3);
        color = 0xCC2244; if(!(i&1)) color = 0x2266CC;
        PresentScene(color);
        if(i&1) GuiPoll(&e); else if(!GuiPresent) throw(4);
        PresentWait(w);
    }
    // A no-op present changes no revision or damage. Direct writes are staged
    // too, and only the clipped dirty region is copied at the frame boundary.
    revision = w->revision;
    if(!GuiPresent || w->revision != revision || w->pending) throw(5);
    p = GrPixels(&stride); p[100*(stride/4)+250] = 0xFF2266CC;
    p[100*(stride/4)+251] = 0xFF2266CC;
    GrDirty(250, 100, 1, 1); GuiPresent; PresentWait(w);
    if(w->pixels[(GUI_TITLE+GUI_PAD+100)*w->scale*w->pw+(1+GUI_PAD+251)*w->scale] != 0xFFCC2244) throw(6);
    p[100*(stride/4)+250] = 0xFFCC2244;
    p[100*(stride/4)+251] = 0xFFCC2244;
    GrDirty(250, 100, 2, 1); GuiPresent; PresentWait(w);
    GuiLog("PRESENT PASS\n");
    while(TRUE) Sleep(100);
}
U0 PresentLaunch() {Spawn(&PresentProbe, NULL, "Present probe", 0, adam_task);}
'''


def client(raw, scale):
    width = 800 * scale
    x, y = 204 * scale, 145 * scale
    return b''.join(raw[((y + row) * width + x) * 4:((y + row) * width + x + 320 * scale) * 4]
                    for row in range(160 * scale))


def boot(mode, scale):
    d = OUT / f'{mode}-{scale}x'
    d.mkdir(parents=True, exist_ok=True)
    frames = d / 'frames'
    frames.mkdir(exist_ok=True)
    for old in frames.glob('*.raw'):
        old.unlink()
    disk = d / 'disk.img'
    testvm.create_disk(disk)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    if mode == 'venus':
        subprocess.run([ROOT / 'tools/venus/install.sh', disk], check=True, stdout=subprocess.DEVNULL)
    fixture = d / 'Present.cool'
    # The dirty-copy test uses physical GrPixels coordinates at either scale.
    fixture.write_text(FIXTURE.replace('100*(stride/4)+250', '100*w->scale*(stride/4)+250*w->scale')
                      .replace('100*(stride/4)+251', '100*w->scale*(stride/4)+251*w->scale'))
    subprocess.run(['mcopy', '-o', '-i', disk, fixture, '::Present.cool'], check=True)
    script = testvm.BOOT + testvm.typed('FontSet(NULL); Gui;\n') + 'wait GUI WINDOWS READY\n'
    script += testvm.typed('#include "C:/Present.cool"\nPresentLaunch;\n')
    script += 'wait PRESENT READY\nwait PRESENT PASS\ndelay 40\nquit\n'
    (d / 'input.txt').write_text(script)
    env = dict(os.environ, COOLVM_FRAMES=str(frames))
    testvm.run_vm(testvm.vm_command(KERNEL,
        executable=ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm'),
        no_venus=mode == 'cpu', size=(800*scale, 600*scale), scale=scale,
        timeout=80, host_timeout=100, disk=disk, input_script=d / 'input.txt',
        screenshot=d / 'screen.png'), d / 'vm.log', env=env, stdin=subprocess.DEVNULL, check=True)
    log = (d / 'vm.log').read_text(errors='replace')
    assert not any(s in log for s in ('ERROR:', 'VENUS FAIL', 'Exception:')), log[-3000:]
    assert 'PRESENT PASS' in log, log[-3000:]
    scenes = {}
    observed = 0
    # Identify committed scenes by their background. Once the first is visible,
    # every subsequent frame must retain its text/buttons and full background.
    for path in sorted(frames.glob('*.raw')):
        scene = client(path.read_bytes(), scale)
        color = scene[:3]
        if not scenes and color != b'\x44\x22\xcc':
            continue  # window creation precedes the first app frame
        assert color in (b'\x44\x22\xcc', b'\xcc\x66\x22'), f'{mode}-{scale}x: cleared frame {path.name}'
        if color not in scenes:
            scenes[color] = scene
            # Text and both buttons must have ink in the completed scene.
            assert scene.count(b'\x00\x00\x00\xff') > 150 * scale * scale
        # The sparse-copy probe intentionally changes just one physical pixel.
        reference = scenes[color]
        offset = (100*scale*320*scale + 250*scale) * 4
        assert scene[:offset] == reference[:offset] and scene[offset+4:] == reference[offset+4:], f'{mode}-{scale}x: partial drawing in {path.name}'
        observed += 1
    assert len(scenes) == 2 and observed >= 30, (mode, scale, len(scenes), observed)
    print(f'gui-present-test: {mode}-{scale}x, {observed} frames, delayed clear, explicit/poll present, dirty copy PASS', flush=True)
    # Keep the final screenshot and fixture; raw snapshots are large and reproducible.
    for path in frames.glob('*.raw'):
        path.unlink()


for scale in (1, 2):
    boot('cpu', scale)
    if '--venus' in sys.argv:
        boot('venus', scale)
