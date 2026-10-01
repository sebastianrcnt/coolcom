#!/usr/bin/env python3
"""OS.Ui framework acceptance in the VM: the Gallery and framework apps on the
CPU and Venus compositors at 1x and 2x. Checks messages, focus, shortcuts,
damage-limited redraw (UI FRAME traces), classic chrome pixels, exact 2x
integer scaling, CPU/Venus equality and input-to-composition latency.

Usage: ui-test.py build/kernel.Image [--venus] [--stage U1,...]
Screenshots: build/ui-<stage>/<session>/shot-NNN.png and screen.png.
"""
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import uivm
import testvm
from uivm import Script, nodes, frames, latency, pixel
from testvm import ROOT

KERNEL = sys.argv[1]
VENUS = '--venus' in sys.argv
STAGES = sys.argv[sys.argv.index('--stage') + 1].split(',') if '--stage' in sys.argv else ['U1']
OUT = ROOT / 'build/ui-u1'
BLACK, WHITE = (0, 0, 0), (255, 255, 255)
FRAME_BUDGET_US = 16000
LOADED_BOUND_US = 50000


BURST = '''U0 UiBurst(I64 tabs)
{// Queue keys for the newest pixel window in one compositor backlog.
    I64 i, daif; CGuiWindow *w = NULL;
    for (i = 0; i < gui.count; i++) if (gui.windows[i]->pixel) w = gui.windows[i];
    GuiFocus(w);
    daif = ArchDaif; ArchIrqOff;
    for (i = 0; i < tabs; i++) GuiKey(KEY_TAB);
    GuiKey(' ');
    ArchIntRestore(daif);
    Print("UI BURST QUEUED\\n");
}
'''


def install_burst(disk, d):
    (d / 'UiBurst.cool').write_text(BURST)
    subprocess.run(['mcopy', '-o', '-i', disk, d / 'UiBurst.cool', '::UiBurst.cool'], check=True)


def start(script, command, ready):
    script.typed('FontSet(NULL); Gui;\n')
    script.wait('GUI WINDOWS READY')
    # The GUI shell window has its own compiler state: define test helpers there.
    script.typed('#include "C:/UiBurst.cool"\n')
    script.typed('gui.trace=1; ' + command + '\n')
    script.wait(ready)
    script.wait('UI FRAME 1 ')
    script.delay(200)


def layout_of(name, command, ready, window=1):
    """Phase 1: the traced layout of an app (logical, identical at every scale)."""
    s = Script()
    start(s, command, ready)
    s.quit()
    log, _, _ = uivm.run(name + '-layout', s, out=ROOT / 'build' / ('ui-' + name), kernel=KERNEL, prepare=install_burst)
    found, entries = nodes(log)
    assert found, log[-3000:]
    return found, entries


def center(rect, origin):
    x, y, w, h = rect
    return origin[0] + x + w // 2, origin[1] + y + h // 2


def check_log(log):
    for bad in ('ERROR:', 'Type Error', 'Linearity Error', 'VENUS FAIL', 'Abort', 'abort:'):
        assert bad not in log, log[-4000:]


# ---------------------------------------------------------------- U1

def u1_session(mode, scale, layout):
    found, _ = layout
    o = uivm.client_origin(1)
    s = Script(scale=scale, size=(800 * scale, 600 * scale))
    start(s, 'GuiGallery;', 'GALLERY READY')
    s.wait('GALLERY TICK 2')                             # two idle timer ticks first
    s.shot()                                             # 0: initial frame
    # Classic tracking: press shows the inverted button, release inside fires.
    s.move(*center(found['Two'], o)); s.press(); s.delay(150)
    s.shot()                                             # 1: Two held
    s.release(); s.wait('GALLERY CLICK 2'); s.delay(150)
    # Tab focuses the first button (dotted ring); Space presses it.
    s.key('tab'); s.delay(150)
    s.shot()                                             # 2: focus ring on One
    s.key('space'); s.wait('GALLERY CLICK 1')
    s.key('enter'); s.wait('GALLERY CLICK 9')         # Return: the default button
    s.key('esc'); s.wait('GALLERY RESET')               # Escape: the cancel button
    s.key('r', ctrl=True); s.wait('GALLERY RESET')      # declared shortcut
    # Drag the split bar 60 px to the right: relayout, kept by the framework.
    left = found['Left pane']
    bar = (o[0] + left[0] + left[2] + 3, o[1] + left[1] + 60)
    s.move(*bar); s.press(); s.delay(30)
    for dx in range(10, 61, 10):
        s.move(bar[0] + dx, bar[1]); s.delay(15)
    s.release(); s.delay(200)
    s.shot()                                             # 3: split moved
    # Latency phase (no screenshots): clicks, focus keys, default/cancel and a shortcut.
    s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    for label, marker in (('Two', 'GALLERY CLICK 2'), ('Three', 'GALLERY CLICK 3'), ('One', 'GALLERY CLICK 1')):
        s.click(*center(found[label], o)); s.wait(marker); s.delay(60)
    for _ in range(2):                                   # One -> Two -> Three
        s.key('tab'); s.delay(60)
    s.key('space'); s.wait('GALLERY CLICK 3'); s.delay(60)
    s.key('enter'); s.wait('GALLERY CLICK 9'); s.delay(60)
    s.key('esc'); s.wait('GALLERY RESET'); s.delay(60)
    s.key('r', ctrl=True); s.wait('GALLERY RESET'); s.delay(60)
    # Only the button and the two labels change on a click.
    s.click(*center(found['One'], o)); s.wait('GALLERY CLICK 1'); s.delay(200)
    s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    # Coalescing: 30 Tab presses (focus cycles back to One) and Space queued at
    # once from the shell (UiBurst focuses the gallery with interrupts masked).
    s.click(300, 44)                                     # the shell's title bar
    s.typed('UiBurst(30);\n'); s.wait('UI BURST QUEUED')
    s.wait('GALLERY CLICK ')                             # Space presses whichever button has focus
    s.delay(200)
    s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    s.quit(200)
    name = f'u1-{mode}-{scale}x'
    log, screen, shots = uivm.run(name, s, out=OUT, kernel=KERNEL, mode=mode, scale=scale, size=(800 * scale, 600 * scale), prepare=install_burst)
    check_log(log)
    return name, log, screen, shots


def u1_check(name, log, screen, shots, scale, layout):
    found, entries = layout
    o = uivm.client_origin(1)
    s = scale
    _, _, initial = testvm.read_png(shots[0])
    _, _, held = testvm.read_png(shots[1])
    _, _, ring = testvm.read_png(shots[2])
    _, _, moved = testvm.read_png(shots[3])
    P = lambda rows, x, y: pixel(rows, x * s, y * s)
    two = found['Two']; one = found['One']; ok = found['OK']
    # Default button: three-pixel ring, a white gap, then the button outline.
    ox, oy = o[0] + ok[0], o[1] + ok[1] + ok[3] // 2
    assert [P(initial, ox + i, oy) for i in range(6)] == [BLACK, BLACK, BLACK, WHITE, BLACK, WHITE], 'default ring'
    # Normal button: white face with black outline; held: inverted face.
    cx, cy = o[0] + two[0] + 4, o[1] + two[1] + two[3] // 2
    assert P(initial, cx, cy) == WHITE and P(initial, o[0] + two[0], cy) == BLACK, 'button face'
    assert P(held, cx, cy) == BLACK, 'pressed button is inverted'
    # Rounded corners: the corner pixel itself is not part of the outline.
    assert P(initial, o[0] + two[0], o[1] + two[1]) == WHITE and P(initial, o[0] + two[0] + 4, o[1] + two[1]) == BLACK, 'rounded corner'
    # Keyboard focus: a dotted ring three pixels inside the face of One.
    rx, ry = o[0] + one[0] + 3, o[1] + one[1] + 3
    dots = [P(ring, rx + i, ry) for i in range(8, 20)]
    assert BLACK in dots and WHITE in dots, 'dotted focus ring'
    assert all(P(initial, rx + i, ry) == WHITE for i in range(8, 20)), 'no ring before Tab'
    # The split bar moved 60 px: the right pane's frame starts later.
    right = found['Right pane']
    assert P(initial, o[0] + right[0], o[1] + right[1] + 40) == BLACK
    assert P(moved, o[0] + right[0] + 60, o[1] + right[1] + 40) == BLACK, 'right pane after drag'
    # Damage: the final click repaints the button and the two changed labels only.
    fs = frames(log)
    assert fs and fs[0][4], 'first frame is a full paint'
    window = 420 * 360
    partial = [f for f in fs[1:] if not f[4]]
    assert partial, 'later frames are damage-limited'
    last = fs[-1]
    area = sum(w * h for _, _, w, h in last[3])
    assert 0 < area < window // 4, f'last frame damage {last[3]}'
    # The burst of 30 focus changes paints far fewer frames than events.
    # The queued burst: 31 keys, one message, at most two frames.
    burst = log.split('UI BURST QUEUED', 1)[1].split('GUI LATENCY n=', 1)[0]
    burst_frames = len(re.findall(r'^UI FRAME ', burst, re.M))
    assert 1 <= burst_frames <= 2, f'{burst_frames} frames for 31 queued keys'
    # Timer ticks rebuild the view but change nothing on screen.
    ticks = log.split('GALLERY TICK 1', 1)[1].split('GALLERY TICK 2', 1)[0]
    assert 'UI FRAME' not in ticks, 'a tick repainted'
    # Input to composed frame: the median within one frame; every sample within
    # a loaded-host bound (make -j test oversubscribes the CPUs; the guest counter
    # keeps running while the VM is descheduled).
    reports = uivm.latencies(log)
    assert len(reports) == 3 and reports[1]['n'] >= 6, f'latency samples {reports}'
    _, lat, burst_lat = reports
    assert lat['p50'] < FRAME_BUDGET_US and lat['max'] < LOADED_BOUND_US, f'input to composed frame {lat}'
    assert burst_lat['max'] < LOADED_BOUND_US, f'queued burst {burst_lat}'
    paint = max(f[2] for f in fs[1:])
    return {'latency': lat, 'burst_frames': burst_frames, 'burst_latency': burst_lat, 'frames': len(fs), 'first_paint_us': fs[0][2], 'max_partial_paint_us': paint,
            'last_damage': last[3]}


def compare_scaled(one, two, region):
    """The 2x screenshot equals the 1x one with every pixel doubled, inside region."""
    _, _, a = testvm.read_png(one)
    _, _, b = testvm.read_png(two)
    x0, y0, w, h = region
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            p = pixel(a, x, y)
            for dy in (0, 1):
                for dx in (0, 1):
                    assert pixel(b, 2 * x + dx, 2 * y + dy) == p, f'2x pixel ({x},{y}) differs'


def compare_equal(one, two, scale=1, skip_clock=True):
    w, h, a = testvm.read_png(one)
    _, _, b = testvm.read_png(two)
    for y in range(h):
        end = 3 * (w - 60 * scale) if (skip_clock and y < 22 * scale) else 3 * w
        assert a[y][:end] == b[y][:end], f'CPU/Venus row {y} differs'


def run_u1():
    layout = layout_of('u1', 'GuiGallery;', 'GALLERY READY')
    sessions = [('cpu', 1), ('cpu', 2)] + ([('venus', 1), ('venus', 2)] if VENUS else [])
    results = {}
    # One VM at a time: make -j test already runs many VM suites side by side.
    with concurrent.futures.ThreadPoolExecutor(max_workers=int(os.environ.get("UI_TEST_JOBS", "1"))) as pool:
        futures = {pool.submit(u1_session, m, sc, layout): (m, sc) for m, sc in sessions}
        for f in concurrent.futures.as_completed(futures):
            mode, scale = futures[f]
            name, log, screen, shots = f.result()
            results[(mode, scale)] = (name, screen, shots, u1_check(name, log, screen, shots, scale, layout))
            print(f'ui-test: {name} PASS {json.dumps(results[(mode, scale)][3])}', flush=True)
    # Crisp integer scaling of the gallery window (client plus chrome).
    region = (44, 58, 430, 395)
    for i in range(4):
        compare_scaled(results[('cpu', 1)][2][i], results[('cpu', 2)][2][i], region)
    if VENUS:
        for sc in (1, 2):
            compare_equal(results[('cpu', sc)][1], results[('venus', sc)][1], sc)
            for i in range(4):
                compare_equal(results[('cpu', sc)][2][i], results[('venus', sc)][2][i], sc)
    summary = {f'{m}-{sc}x': r[3] for (m, sc), r in results.items()}
    (OUT / 'u1-results.json').write_text(json.dumps(summary, indent=1))
    print('ui-test: U1 PASS', flush=True)


if 'U1' in STAGES:
    run_u1()
