#!/usr/bin/env python3
"""OS.Ui framework acceptance in the VM: the UiCheck and Gallery apps on the
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
OUT2 = ROOT / 'build/ui-u2'
OUT3 = ROOT / 'build/ui-u3'
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


def start(script, command, ready, trace=1):
    script.typed('FontSet(NULL); Gui;\n')
    script.wait('GUI WINDOWS READY')
    # The GUI shell window has its own compiler state: define test helpers there.
    script.typed('#include "C:/UiBurst.cool"\n')
    script.typed(f'gui.trace={trace}; ' + command + '\n')
    script.wait(ready)
    script.wait('UI FRAME 1 ')
    script.delay(200)


def layout_of(name, command, ready, window=1):
    """Phase 1: the traced layout of an app (logical, identical at every scale)."""
    s = Script()
    start(s, command, ready, trace=2)
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
    start(s, 'GuiRun("C:/Warm/Examples/gui/UiCheck.warm", "UiCheck:main");', 'CHECK READY')
    s.wait('CHECK TICK 2')                             # two idle timer ticks first
    s.shot()                                             # 0: initial frame
    # Classic tracking: press shows the inverted button, release inside fires.
    s.move(*center(found['Two'], o)); s.press(); s.delay(150)
    s.shot()                                             # 1: Two held
    s.release(); s.wait('CHECK CLICK 2'); s.delay(150)
    # Tab focuses the first button (dotted ring); Space presses it.
    s.key('tab'); s.delay(150)
    s.shot()                                             # 2: focus ring on One
    s.key('space'); s.wait('CHECK CLICK 1')
    s.key('enter'); s.wait('CHECK CLICK 9')         # Return: the default button
    s.key('esc'); s.wait('CHECK RESET')               # Escape: the cancel button
    s.key('r', ctrl=True); s.wait('CHECK RESET')      # declared shortcut
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
    for label, marker in (('Two', 'CHECK CLICK 2'), ('Three', 'CHECK CLICK 3'), ('One', 'CHECK CLICK 1')):
        s.click(*center(found[label], o)); s.wait(marker); s.delay(60)
    for _ in range(2):                                   # One -> Two -> Three
        s.key('tab'); s.delay(60)
    s.key('space'); s.wait('CHECK CLICK 3'); s.delay(60)
    s.key('enter'); s.wait('CHECK CLICK 9'); s.delay(60)
    s.key('esc'); s.wait('CHECK RESET'); s.delay(60)
    s.key('r', ctrl=True); s.wait('CHECK RESET'); s.delay(60)
    # Only the button and the two labels change on a click.
    s.click(*center(found['One'], o)); s.wait('CHECK CLICK 1'); s.delay(200)
    s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    # Coalescing: 30 Tab presses (focus cycles back to One) and Space queued at
    # once from the shell (UiBurst focuses the gallery with interrupts masked).
    s.click(300, 44)                                     # the shell's title bar
    s.typed('UiBurst(30);\n'); s.wait('UI BURST QUEUED')
    s.wait('CHECK CLICK ')                             # Space presses whichever button has focus
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
    ticks = log.split('CHECK TICK 1', 1)[1].split('CHECK TICK 2', 1)[0]
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
    layout = layout_of('u1', 'GuiRun("C:/Warm/Examples/gui/UiCheck.warm", "UiCheck:main");', 'CHECK READY')
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


# ---------------------------------------------------------------- U2

SHIFT_SPACE = '1 42 1\n1 57 1\n1 57 0\n1 42 0\ndelay 30\n'


def u2_session(mode, scale, layout):
    found, _ = layout
    o = uivm.client_origin(1)
    s = Script(scale=scale, size=(800 * scale, 600 * scale))
    start(s, 'GuiGallery;', 'GALLERY READY')
    s.shot()                                             # 0: every control at rest
    # Checkbox and radio: click the title; the model flips/chooses.
    s.click(*center(found['Italic'], o)); s.wait('GALLERY ITALIC true')
    s.click(*center(found['Large'], o)); s.wait('GALLERY SIZE 3')
    # Slider: drag the thumb right, then step with the keyboard (the slider took focus).
    slider = found['@slider']
    thumb_x = o[0] + slider[0] + (slider[2] - 11) * 40 // 100 + 5
    y = o[1] + slider[1] + slider[3] // 2
    s.move(thumb_x, y); s.press(); s.delay(30)
    for dx in range(8, 49, 8):
        s.move(thumb_x + dx, y); s.delay(15)
    s.release(); s.wait('GALLERY VOLUME '); s.delay(100)
    s.key('right'); s.delay(100)
    s.shot()                                             # 1: Italic, Large, slider moved, slider focused
    # Text: type, select with Shift+Left, copy, paste at the end.
    name = found['Your name']
    s.click(o[0] + name[0] + 20, o[1] + name[1] + name[3] // 2); s.delay(60)
    s.typed('hello', delay=20); s.wait('GALLERY NAME [hello]')
    s.key('left', shift=True); s.key('left', shift=True); s.delay(60)
    s.key('c', ctrl=True); s.delay(60)
    s.key('end'); s.key('v', ctrl=True); s.wait('GALLERY NAME [hellolo]')
    s.key('left', shift=True); s.key('left', shift=True); s.key('left', shift=True); s.delay(150)
    s.shot()                                             # 2: focused field with an inverted selection
    # Select all and type over it; Backspace empties the field.
    s.key('a', ctrl=True); s.typed('X', delay=20); s.wait('GALLERY NAME [X]')
    s.key('backspace'); s.wait('GALLERY NAME []')
    # Hangul: 2-beolsik composition replaces the syllable as it grows (Backspace + new text).
    s.text += SHIFT_SPACE; s.typed('gksrmf', delay=30); s.text += SHIFT_SPACE
    s.wait('GALLERY NAME [한글]')
    # Double click selects a word; typing replaces it.
    s.typed(' foo bar', delay=20); s.wait('GALLERY NAME [한글 foo bar]')
    text_x = o[0] + name[0] + 4 + 16 * 2 + 8 * 6
    s.move(text_x, o[1] + name[1] + name[3] // 2); s.press(); s.release(); s.press(); s.release(); s.delay(80)
    s.typed('Z', delay=20); s.wait('GALLERY NAME [한글 foo Z]')
    # Copy everything and paste into the password field (bullets, no copying out).
    s.key('a', ctrl=True); s.key('c', ctrl=True); s.delay(60)
    secret = found['@password']
    s.click(o[0] + secret[0] + 20, o[1] + secret[1] + secret[3] // 2); s.delay(60)
    s.key('v', ctrl=True); s.wait('GALLERY SECRET 12')
    s.delay(150)
    s.shot()                                             # 3: Hangul text, password bullets
    # Latency phase: typing into the field.
    s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    s.click(o[0] + name[0] + 20, o[1] + name[1] + name[3] // 2); s.delay(60)
    s.key('end')
    for ch in 'latency':
        s.typed(ch, delay=50)
    s.wait('GALLERY NAME [한글 foo Zlatency]'); s.delay(150)
    s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    s.quit(200)
    name_ = f'u2-{mode}-{scale}x'
    log, screen, shots = uivm.run(name_, s, out=OUT2, kernel=KERNEL, mode=mode, scale=scale, size=(800 * scale, 600 * scale),
                                  prepare=install_burst)
    check_log(log)
    return name_, log, screen, shots


def u2_layout():
    found, entries = layout_of('u2', 'GuiGallery;', 'GALLERY READY')
    # Unlabelled controls by kind (14 slider, 18 text box; the second text box is the password).
    sliders = [e for e in entries if e[1] == 14]
    boxes = [e for e in entries if e[1] == 18]
    found['@slider'] = sliders[0][2:6]
    found['@password'] = boxes[1][2:6]
    found['Your name'] = boxes[0][2:6]
    return found, entries


def u2_check(name, log, screen, shots, scale, layout):
    found, entries = layout
    o = uivm.client_origin(1)
    s = scale
    _, _, rest = testvm.read_png(shots[0])
    _, _, chosen = testvm.read_png(shots[1])
    _, _, selected = testvm.read_png(shots[2])
    _, _, hangul = testvm.read_png(shots[3])
    P = lambda rows, x, y: pixel(rows, x * s, y * s)
    for marker in ('GALLERY ITALIC TRUE', 'GALLERY SIZE 3', 'GALLERY NAME [hellolo]', 'GALLERY NAME [í\u0095\u009c',
                   'GALLERY SECRET 12'):
        pass
    # Checkbox: Bold starts checked (an X through the box), Italic becomes checked.
    bold = found['Bold']; italic = found['Italic']
    def box_x(rows, rect):
        bx, by = o[0] + rect[0], o[1] + rect[1] + (rect[3] - 12) // 2
        return P(rows, bx + 3, by + 3) == BLACK and P(rows, bx + 8, by + 3) == BLACK and P(rows, bx + 5, by + 3) == WHITE
    assert box_x(rest, bold) and not box_x(rest, italic) and box_x(chosen, italic), 'checkbox X'
    # Radio: the dot moves from Medium to Large.
    def dot(rows, rect):
        return P(rows, o[0] + rect[0] + 5, o[1] + rect[1] + (rect[3] - 12) // 2 + 5) == BLACK
    assert dot(rest, found['Medium']) and not dot(rest, found['Large']), 'radio dot at rest'
    assert dot(chosen, found['Large']) and not dot(chosen, found['Medium']), 'radio dot moved'
    # Progress: filled to the slider's value (40% at rest).
    level = [e for e in entries if e[1] == 15][0][2:6]
    lx, ly, lw, lh = o[0] + level[0], o[1] + level[1], level[2], level[3]
    inner = lw - 2
    assert P(rest, lx + 1 + inner * 40 // 100 - 2, ly + lh // 2) == BLACK and P(rest, lx + 1 + inner * 40 // 100 + 2, ly + lh // 2) == WHITE, 'progress 40%'
    volumes = [int(v) for v in re.findall(r'GALLERY VOLUME (\d+)', log)]
    assert volumes and volumes[-1] > 40 and volumes[-1] % 5 == 0, f'slider values {volumes}'
    # Text box: selection is inverted (white text pixels on black).
    nb = found['Your name']
    sel_y = o[1] + nb[1] + nb[3] // 2
    row = [P(selected, x, sel_y) for x in range(o[0] + nb[0] + 4 + 8 * 4, o[0] + nb[0] + 4 + 8 * 7)]
    assert row.count(BLACK) > len(row) // 2, 'inverted selection'
    # The password field shows bullets, not the text.
    pw = found['@password']
    assert any(P(hangul, x, o[1] + pw[1] + pw[3] // 2) == BLACK for x in range(o[0] + pw[0] + 4, o[0] + pw[0] + 40)), 'bullets'
    reports = uivm.latencies(log)
    lat = reports[-1]
    assert lat['n'] >= 5 and lat['p50'] < FRAME_BUDGET_US and lat['max'] < LOADED_BOUND_US, f'typing latency {lat}'
    fs = frames(log)
    typing = log.split('GUI LATENCY', 1)[1].split('GUI LATENCY', 1)[0]
    rects = [f for f in frames(typing)]
    big = [f for f in rects if not f[4] and sum(w * h for _, _, w, h in f[3]) > 560 * 470 // 4]
    assert not big, f'typing repaints large areas {big[:2]}'
    return {'latency': lat, 'volumes': volumes[-1], 'frames': len(fs)}


def run_u2():
    layout = u2_layout()
    sessions = [('cpu', 1), ('cpu', 2)] + ([('venus', 1), ('venus', 2)] if VENUS else [])
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=int(os.environ.get("UI_TEST_JOBS", "1"))) as pool:
        futures = {pool.submit(u2_session, m, sc, layout): (m, sc) for m, sc in sessions}
        for f in concurrent.futures.as_completed(futures):
            mode, scale = futures[f]
            name, log, screen, shots = f.result()
            results[(mode, scale)] = (name, screen, shots, u2_check(name, log, screen, shots, scale, layout))
            print(f'ui-test: {name} PASS {json.dumps(results[(mode, scale)][3])}', flush=True)
    region = (44, 58, 570, 505)
    for i in range(4):
        compare_scaled(results[('cpu', 1)][2][i], results[('cpu', 2)][2][i], region)
    if VENUS:
        for sc in (1, 2):
            compare_equal(results[('cpu', sc)][1], results[('venus', sc)][1], sc)
            for i in range(4):
                compare_equal(results[('cpu', sc)][2][i], results[('venus', sc)][2][i], sc)
    summary = {f'{m}-{sc}x': r[3] for (m, sc), r in results.items()}
    (OUT2 / 'u2-results.json').write_text(json.dumps(summary, indent=1))
    print('ui-test: U2 PASS', flush=True)



# ---------------------------------------------------------------- U3

DATA = 'GuiRun("C:/Warm/Examples/gui/UiData.warm", "UiData:main");'


def u3_layout():
    found, entries = layout_of('u3', DATA, 'DATA READY')
    kinds = {}
    for idx, kind, x, y, w, h, text in entries:
        kinds.setdefault(kind, []).append((x, y, w, h, text))
    found['@table'] = kinds[22][0][:4]
    found['@list'] = kinds[21][0][:4]
    found['@tree'] = kinds[23][0][:4]
    found['@text'] = kinds[24][0][:4]
    found['@headers'] = [(x, y, w, h, t) for x, y, w, h, t in kinds[27]]
    return found, entries


def u3_session(mode, scale, layout):
    found, _ = layout
    o = uivm.client_origin(1)
    s = Script(scale=scale, size=(800 * scale, 600 * scale))
    start(s, DATA, 'DATA READY')
    tx, ty, tw, th = found['@table']
    body_top = ty + 2 + 20
    s.shot()                                             # 0: table, list, tree, text view
    # Wheel: twenty lines down in one burst (three rows a line).
    s.move(o[0] + tx + tw // 2, o[1] + body_top + 60)
    for _ in range(20):
        s.wheel(-1)
    s.wait('DATA TABLE first=60 ')
    # Continuous scrolling, 40 lines 20 ms apart: every frame within budget.
    s.delay(200); s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    for _ in range(40):
        s.wheel(-1); s.delay(20)
    s.wait('DATA TABLE first=180 ')
    s.delay(200); s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    # Scroll bar: drag the thumb to the bottom.
    bar_x = o[0] + tx + tw - 2 - 8
    thumb_y = o[1] + body_top + 16 + 5
    s.move(bar_x, thumb_y); s.press(); s.delay(30)
    s.move(bar_x, o[1] + ty + th - 20); s.delay(30)
    s.release(); s.wait('DATA TABLE first=99')
    # Sort by size (ascending, then descending) from the header.
    headers = {h[4]: h for h in found['@headers']}
    size = headers['Size']
    s.click(o[0] + size[0] + size[2] // 2, o[1] + size[1] + size[3] // 2); s.wait('sort=1 descending=false')
    s.click(o[0] + size[0] + size[2] // 2, o[1] + size[1] + size[3] // 2); s.wait('sort=1 descending=true')
    # Select the third visible row; double click opens it.
    row_y = o[1] + body_top + 2 * 18 + 9
    s.click(o[0] + tx + 40, row_y); s.wait('selected=2 ')
    s.move(o[0] + tx + 40, row_y); s.press(); s.release(); s.wait('DATA OPEN ')
    # Keys move the selection and keep it visible.
    s.key('down'); s.wait('selected=3 ')
    s.key('end'); s.wait('selected=9999 ')
    s.key('home'); s.wait('first=0 selected=0 ')
    # Widen the Name column by dragging its rule 40 px.
    name = headers['Name']
    rule_x = o[0] + name[0] + name[2] - 1
    s.move(rule_x, o[1] + name[1] + 8); s.press(); s.delay(30)
    for dx in (10, 20, 30, 40):
        s.move(rule_x + dx, o[1] + name[1] + 8); s.delay(20)
    s.release(); s.delay(200)
    s.shot()                                             # 1: sorted by size (descending), wider Name column, first row selected
    # Tree: open Folder 0, then its Group 30.
    rx, ry, rw, rh = found['@tree']
    tree_top = o[1] + ry + 2
    s.click(o[0] + rx + 2 + 2 + 8, tree_top + 9); s.wait('DATA TOGGLE 0')
    s.click(o[0] + rx + 2 + 2 + 16 + 8, tree_top + 3 * 18 + 9); s.wait('DATA TOGGLE 30')
    s.click(o[0] + rx + 60, tree_top + 4 * 18 + 9); s.wait('DATA TREE selected=4')
    s.key('down'); s.wait('DATA TREE selected=5')
    # List: select with the mouse, scroll with the wheel.
    lx, ly, lw, lh = found['@list']
    s.click(o[0] + lx + 50, o[1] + ly + 2 + 18 + 9); s.wait('DATA LIST selected=1')
    s.move(o[0] + lx + 50, o[1] + ly + 40); s.wheel(-2); s.delay(150)
    # Text view: a new line at the end, then a word; Up moves to the line above.
    vx, vy, vw, vh = found['@text']
    s.click(o[0] + vx + vw - 30, o[1] + vy + vh - 12); s.delay(80)
    s.key('end', ctrl=False)
    s.key('enter'); s.typed('hello', delay=20); s.wait('DATA TEXT 100')
    s.key('up', shift=True); s.delay(150)
    s.shot()                                             # 2: tree opened, list scrolled, text view with a selection
    # Latency phase: keyboard navigation in the table.
    s.click(o[0] + tx + 40, o[1] + body_top + 18 + 9); s.wait('selected=1 ')
    s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    for i in range(2, 12):                               # a key every frame or two, not back to back
        s.key('down'); s.wait(f'selected={i} '); s.delay(40)
    s.delay(150); s.key('l', ctrl=True, alt=True); s.wait('GUI LATENCY')
    s.quit(200)
    name_ = f'u3-{mode}-{scale}x'
    log, screen, shots = uivm.run(name_, s, out=OUT3, kernel=KERNEL, mode=mode, scale=scale, size=(800 * scale, 600 * scale),
                                  prepare=install_burst, timeout=200)
    check_log(log)
    return name_, log, screen, shots


def u3_check(name, log, screen, shots, scale, layout):
    found, entries = layout
    reports = uivm.latencies(log)
    # Reports: [burst scroll (unused), continuous scroll, (reset by the screenshots), keyboard]
    scroll = reports[1]
    keys = reports[-1]
    assert scroll['n'] >= 10, f'scroll samples {scroll}'
    assert scroll['p50'] < FRAME_BUDGET_US and scroll['max'] < LOADED_BOUND_US, f'scrolling {scroll}'
    assert keys['n'] >= 5 and keys['p50'] < FRAME_BUDGET_US and keys['max'] < LOADED_BOUND_US, f'table keys {keys}'
    # Every frame painted while scrolling: paint (compare + draw) well inside a frame,
    # and the application cycle (update + view + layout) too.
    segment = log.split('GUI LATENCY n=', 2)[1].split('GUI LATENCY n=', 1)[0]
    fs = frames(segment)
    assert len(fs) >= 10, f'{len(fs)} frames while scrolling'
    worst = max(f[2] for f in fs)
    assert worst < FRAME_BUDGET_US, f'paint {worst} us'
    cycles = [int(c) for c in re.findall(r'UI CYCLE app=\d+ layout=(\d+)', segment)]
    apps = [int(c) for c in re.findall(r'UI CYCLE app=(\d+) layout=', segment) if int(c) < 1000000]
    assert cycles and max(cycles) < FRAME_BUDGET_US, f'layout {max(cycles)} us'
    assert apps and max(apps) < FRAME_BUDGET_US, f'update+view {max(apps)} us'
    # Sorting by size descending puts the largest first: rows show decreasing sizes.
    sizes = re.findall(r'sort=1 descending=true', log)
    assert sizes, 'sorted'
    first_states = [int(v) for v in re.findall(r'DATA TABLE first=(\d+)', log)]
    assert max(first_states) >= 9990 - 30, f'thumb drag reached the end {max(first_states)}'
    _, _, rest = testvm.read_png(shots[0])
    _, _, sorted_ = testvm.read_png(shots[1])
    o = uivm.client_origin(1)
    tx, ty, tw, th = found['@table']
    P = lambda rows, x, y: pixel(rows, x * scale, y * scale)
    # The selected (first) row is inverted after Home.
    assert P(sorted_, o[0] + tx + tw // 2, o[1] + ty + 2 + 20 + 9) == BLACK, 'selected row inverted'
    # Classic scroll bar: gray track, white square thumb, at the top again after Home.
    bx = o[0] + tx + tw - 2 - 16
    assert P(rest, bx + 8, o[1] + ty + 2 + 20 + 16 + 8) == WHITE, 'thumb at the top'
    track = [P(rest, bx + 4 + dx, o[1] + ty + th // 2) for dx in range(4)]
    assert BLACK in track and WHITE in track, 'gray track'
    return {'scroll_latency': scroll, 'key_latency': keys, 'scroll_frames': len(fs), 'worst_paint_us': worst,
            'worst_layout_us': max(cycles), 'worst_view_us': max(apps)}


def run_u3():
    layout = u3_layout()
    sessions = [('cpu', 1), ('cpu', 2)] + ([('venus', 1), ('venus', 2)] if VENUS else [])
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=int(os.environ.get("UI_TEST_JOBS", "1"))) as pool:
        futures = {pool.submit(u3_session, m, sc, layout): (m, sc) for m, sc in sessions}
        for f in concurrent.futures.as_completed(futures):
            mode, scale = futures[f]
            name, log, screen, shots = f.result()
            results[(mode, scale)] = (name, screen, shots, u3_check(name, log, screen, shots, scale, layout))
            print(f'ui-test: {name} PASS {json.dumps(results[(mode, scale)][3])}', flush=True)
    region = (44, 58, 610, 505)
    for i in range(3):
        compare_scaled(results[('cpu', 1)][2][i], results[('cpu', 2)][2][i], region)
    if VENUS:
        for sc in (1, 2):
            compare_equal(results[('cpu', sc)][1], results[('venus', sc)][1], sc)
            for i in range(3):
                compare_equal(results[('cpu', sc)][2][i], results[('venus', sc)][2][i], sc)
    summary = {f'{m}-{sc}x': r[3] for (m, sc), r in results.items()}
    (OUT3 / 'u3-results.json').write_text(json.dumps(summary, indent=1))
    print('ui-test: U3 PASS', flush=True)


if 'U1' in STAGES:
    run_u1()
if 'U2' in STAGES:
    run_u2()
if 'U3' in STAGES:
    run_u3()
