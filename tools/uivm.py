#!/usr/bin/env python3
"""Shared VM plumbing for OS.Ui tests: scripted pointer/keys in window-client
coordinates, mid-run screenshots (Ctrl+Alt+P -> C:/Shots), UI traces and PNG output.

Logical coordinates are scaled to physical absolute pointer positions. The
kernel places the k-th window at (20 + 24k, 34 + 24k); its client area starts
4 pixels right and 25 pixels down from there.
"""
import pathlib
import re
import struct
import subprocess
import zlib
import testvm
from testvm import ROOT

LEFT_CTRL, LEFT_ALT, LEFT_SHIFT, BTN_LEFT = 29, 56, 42, 272
KEYCODES = {'enter': 28, 'esc': 1, 'tab': 15, 'backspace': 14, 'space': 57, 'up': 103, 'down': 108,
            'left': 105, 'right': 106, 'home': 102, 'end': 107, 'pageup': 104, 'pagedown': 109, 'delete': 111}


def client_origin(window_index):
    return 20 + 24 * window_index + 4, 34 + 24 * window_index + 25


class Script:
    def __init__(self, scale=1, size=(800, 600)):
        self.scale, self.size = scale, size
        self.text = testvm.BOOT
        self.shots = 0
        self.buttons = 0

    def raw(self, line):
        self.text += line if line.endswith('\n') else line + '\n'

    def wait(self, marker):
        self.raw(f'wait {marker}')

    def delay(self, ms):
        self.raw(f'delay {ms}')

    def typed(self, text, delay=3):
        self.text += testvm.typed(text, delay=delay)

    def key(self, name, *, ctrl=False, alt=False, shift=False):
        code = KEYCODES.get(name)
        if code is None:
            code, needs_shift = testvm.KEYS[name]
            shift = shift or needs_shift
        mods = [m for m, on in ((LEFT_CTRL, ctrl), (LEFT_ALT, alt), (LEFT_SHIFT, shift)) if on]
        for m in mods:
            self.raw(f'1 {m} 1')
        self.text += testvm.keys_of(code)
        for m in reversed(mods):
            self.raw(f'1 {m} 0')

    def move(self, x, y):
        """Screen logical coordinates (centre of the logical pixel)."""
        s = self.scale
        self.text += testvm.pointer_absolute(x * s + s // 2, y * s + s // 2, self.size[0], self.size[1])
        self.raw('0 0 0')

    def press(self):
        self.raw(f'1 {BTN_LEFT} 1')

    def release(self):
        self.raw(f'1 {BTN_LEFT} 0')

    def click(self, x, y, settle=20):
        self.move(x, y); self.press(); self.release()
        if settle:
            self.delay(settle)

    def wheel(self, lines):
        self.raw(f'2 8 {lines}')
        self.raw('0 0 0')

    def shot(self):
        """Ctrl+Alt+P: the compositor saves C:/Shots/NNN.BMP after composing."""
        index = self.shots
        self.key('p', ctrl=True, alt=True)
        self.wait(f'GUI SHOT {index}')
        self.shots += 1
        return index

    def quit(self, settle=100):
        self.delay(settle)
        self.raw('quit')


def nodes(log):
    """{text: (x, y, w, h)} of the last traced layout, plus a list of all nodes."""
    blocks = log.split('UI FRAME')
    found = {}
    entries = []
    for m in re.finditer(r'^UI NODE (\d+) (\d+) (-?\d+) (-?\d+) (\d+) (\d+) ?(.*)$', log, re.M):
        idx, kind, x, y, w, h, text = m.groups()
        entries.append((int(idx), int(kind), int(x), int(y), int(w), int(h), text))
        if text:
            found[text] = (int(x), int(y), int(w), int(h))
    return found, entries


def frames(log):
    """[(frame, nodes, microseconds, [rects], full)] from UI FRAME traces."""
    result = []
    for m in re.finditer(r'^UI FRAME (\d+) nodes=(\d+) us=(\d+)( full)?((?: -?\d+,-?\d+,\d+,\d+)*)\s*$', log, re.M):
        rects = [tuple(map(int, r.split(','))) for r in m.group(5).split()]
        result.append((int(m.group(1)), int(m.group(2)), int(m.group(3)), rects, bool(m.group(4))))
    return result


def latencies(log):
    """Every GUI LATENCY report (Ctrl+Alt+L prints and resets the samples)."""
    result = []
    for n, mx, p50, p95, mean in re.findall(r'GUI LATENCY n=(\d+)(?: max=(\d+) p50=(\d+) p95=(\d+) mean=(\d+))?', log):
        result.append({'n': int(n), 'max': int(mx or 0), 'p50': int(p50 or 0), 'p95': int(p95 or 0), 'mean': int(mean or 0)})
    return result


def latency(log):
    """The last GUI LATENCY report as a dict of microsecond values."""
    reports = re.findall(r'GUI LATENCY n=(\d+)(?: max=(\d+) p50=(\d+) p95=(\d+) mean=(\d+))?', log)
    if not reports:
        return None
    n, mx, p50, p95, mean = reports[-1]
    return {'n': int(n), 'max': int(mx or 0), 'p50': int(p50 or 0), 'p95': int(p95 or 0), 'mean': int(mean or 0)}


def run(name, script, *, out, kernel, mode='cpu', scale=1, size=(800, 600), timeout=150, prepare=None, frames_dir=None):
    """Boot a fresh disk, run the script; return (log text, final screenshot rows, shot paths)."""
    d = out / name
    d.mkdir(parents=True, exist_ok=True)
    for old in d.glob('shot-*.png'):
        old.unlink()
    disk = d / 'disk.img'
    # Screenshots at 2x are 7.7 MB each: leave room for a dozen beside the installed files.
    testvm.create_disk(disk, 192 * 1024 * 1024)
    testvm.install_disk_files(disk, stdout=subprocess.DEVNULL)
    if mode == 'venus':
        subprocess.run([ROOT / 'tools/venus/install.sh', disk], check=True, stdout=subprocess.DEVNULL)
    if prepare:
        prepare(disk, d)
    (d / 'input.txt').write_text(script.text)
    vm = ROOT / ('build/coolvm-venus' if mode == 'venus' else 'build/coolvm')
    env = None
    if frames_dir:
        import os
        env = dict(os.environ, COOLVM_FRAMES=str(frames_dir))
    testvm.run_vm(testvm.vm_command(kernel, executable=vm, no_venus=mode == 'cpu', size=size, scale=scale,
                                    timeout=timeout, host_timeout=timeout + 20, disk=disk,
                                    input_script=d / 'input.txt', screenshot=d / 'screen.png'),
                  d / 'vm.log', stdin=subprocess.DEVNULL, check=True, env=env)
    log = (d / 'vm.log').read_text(errors='replace')
    shots = []
    for i in range(script.shots):
        bmp = d / f'shot-{i:03d}.bmp'
        subprocess.run(['mcopy', '-o', '-i', disk, f'::Shots/{i:03d}.BMP', bmp], check=True)
        png = d / f'shot-{i:03d}.png'
        write_png(png, *read_bmp(bmp))
        bmp.unlink()
        shots.append(png)
    disk.unlink()
    return log, d / 'screen.png', shots


def read_bmp(path):
    """(width, height, rows of RGB bytes) from the kernel's top-down 32-bit BMP."""
    data = path.read_bytes()
    off, = struct.unpack_from('<I', data, 10)
    w, h = struct.unpack_from('<ii', data, 18)
    h = abs(h)
    rows = []
    for y in range(h):
        line = data[off + y * w * 4: off + (y + 1) * w * 4]
        rgb = bytearray(w * 3)
        rgb[0::3] = line[2::4]
        rgb[1::3] = line[1::4]
        rgb[2::3] = line[0::4]
        rows.append(bytes(rgb))
    return w, h, rows


def write_png(path, w, h, rows):
    raw = b''.join(b'\x00' + r for r in rows)
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
    pathlib.Path(path).write_bytes(png)


def crop(rows, x, y, w, h):
    return [r[3 * x:3 * (x + w)] for r in rows[y:y + h]]


def save_crop(path, rows, x, y, w, h):
    write_png(path, w, h, crop(rows, x, y, w, h))


def pixel(rows, x, y):
    return tuple(rows[y][3 * x:3 * x + 3])
