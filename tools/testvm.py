"""Shared host-side VM test plumbing; guest scenarios and assertions stay in callers.

All paths are explicit so parallel tests keep separate disks, scripts and logs.
The two typing helpers preserve the suites' paced and unpaced input conventions.
"""
import pathlib
import re
import struct
import subprocess
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
W, H = 640, 480

KEYS = {'\\': (43, False), ' ': (57, False), '\n': (28, False), '\x1b': (1, False),
        '\b': (14, False), '\t': (15, False),
        '`': (41, False), '~': (41, True), '|': (43, True)}
for first, lo, up in ((2, '1234567890-=', '!@#$%^&*()_+'),
                      (16, 'qwertyuiop[]', 'QWERTYUIOP{}'),
                      (30, "asdfghjkl;'", 'ASDFGHJKL:"'),
                      (44, 'zxcvbnm,./', 'ZXCVBNM<>?')):
    for i, (plain, shifted) in enumerate(zip(lo, up)):
        KEYS[plain] = (first + i, False)
        KEYS[shifted] = (first + i, True)


def keys_of(code):
    return f'1 {code} 1\n1 {code} 0\n'


def pointer_absolute(x, y, width, height):
    """Place the pointer at physical pixels through Linux ABS_X/ABS_Y.

    Round up so Input.cool's integer conversion maps back to the exact pixel.
    Coordinates and framebuffer dimensions are explicit for HiDPI scripts.
    """
    if not (2 <= width <= 32768 and 2 <= height <= 32768 and 0 <= x < width and 0 <= y < height):
        raise ValueError('absolute pointer outside framebuffer')
    ax = (x * 32767 + width - 2) // (width - 1)
    ay = (y * 32767 + height - 2) // (height - 1)
    return f'3 0 {ax}\n3 1 {ay}\n'


def typed(text, *, delay=3):
    """Type literal text using Linux key codes, with delay ms after each character."""
    result = ''
    for ch in text:
        if ch in ('\x12', '\x0f'):
            result += '1 29 1\n' + keys_of(19 if ch == '\x12' else 24) + '1 29 0\n'
        else:
            code, shift = KEYS[ch]
            if shift:
                result += '1 42 1\n'
            result += keys_of(code)
            if shift:
                result += '1 42 0\n'
        if delay:
            result += f'delay {delay}\n'
    return result


# Input-script sync (tools/coolvm/README.md): the shell has started (and run C:/Init.cool) and shows its
# prompt. Waiting for guest output instead of a fixed boot delay keeps the scripts right when
# the host is loaded (make -j test); QUIT ends the VM instead of idling until --timeout.
# A wait text must not occur in the echo of the lines typed before it: print numbers with
# %d (Print("OPEN%d", 2) echoes as OPEN%d but prints OPEN2).
BOOT = 'wait Cool shell\nwait > \n'


def wait(text):
    return f'wait {text}\n'


def finish(text, settle=200):
    """Wait for text, give the screen settle ms, then stop the VM (the screenshot is saved)."""
    return wait(text) + f'delay {settle}\nquit\n'


def check_init_log(log):
    marker = 'Running C:/Init.cool\n'
    if marker not in log:
        raise AssertionError('shell did not run C:/Init.cool')
    after_init = log.split(marker, 1)[1]
    prompt = re.search(r'(?m)^(?:[A-Z]:\S*)?> ', after_init)  # "C:/> ", or "> " without a drive
    if not prompt:
        raise AssertionError('shell did not reach a prompt after C:/Init.cool')
    diagnostics = re.findall(r'^(?:ERROR|WARNING):.*$', after_init[:prompt.start()], re.MULTILINE)
    if diagnostics:
        raise AssertionError('C:/Init.cool diagnostics:\n' + '\n'.join(diagnostics))


def typed_line(line, enter=True):
    """Unpaced shell input, optionally followed by ENTER (kernel device tests)."""
    return typed(line + ('\n' if enter else ''), delay=0)


def create_disk(path, size=64 * 1024 * 1024, *, label=None, cluster_size=None,
                capture_output=False):
    """Create a fresh FAT32 image, optionally with fixed-size clusters.

    mformat supplies its usual layout by default. Device/Tmux tests use
    newfs_msdos with 512-byte clusters to preserve their existing disk layout.
    """
    path = pathlib.Path(path)
    with path.open('wb') as stream:
        stream.truncate(size)
    if cluster_size is None:
        args = ['mformat', '-i', str(path), '-F']
        if label is not None:
            args += ['-v', label]
        args += ['::']
    else:
        args = ['newfs_msdos', '-F', '32', '-S', '512', '-c', str(cluster_size // 512),
                '-s', str(size // 512), '-h', '16', '-u', '63']
        if label is not None:
            args += ['-v', label]
        args.append(str(path))
    subprocess.run(args, check=True, capture_output=capture_output)
    return path


def install_disk_files(disk, *, stdout=None, capture_output=False):
    """Populate the image with the production installer, without adding fixtures."""
    subprocess.run([str(ROOT / 'tools/disk-files.sh'), str(disk)], check=True,
                   stdout=stdout, capture_output=capture_output)


def vm_command(kernel=None, *, executable=ROOT / 'build/coolvm', headless=True,
               no_venus=False, cpus=2, mem=1024, timeout, size=None, scale=None,
               input_script=None, disk=None, screenshot=None, extra=(), host_timeout=None):
    """Build coolvm argv; keep renderer choice and both timeout policies explicit.

    kernel=None builds a prefix for callers that append options or the image later.
    host_timeout uses the suites' existing gtimeout with a two-second kill grace.
    """
    args = [str(executable)]
    if headless:
        args.append('--headless')
    if no_venus:
        args.append('--no-venus')
    args += ['--cpus', str(cpus), '--mem', str(mem), '--timeout', str(timeout)]
    if size is not None:
        args += ['--width', str(size[0]), '--height', str(size[1])]
    for flag, value in [('--scale', scale), ('--input-script', input_script),
                        ('--disk', disk), ('--screenshot', screenshot)]:
        if value is not None:
            args += [flag, str(value)]
    args += list(map(str, extra))
    if kernel is not None:
        args.append(str(kernel))
    if host_timeout is not None:
        args = ['gtimeout', '-k', '2', str(host_timeout), *args]
    return args


def run_vm(command, log, **kwargs):
    """Run a VM with merged stdout/stderr in log; return its original exit status.

    Callers retain check/timeout/stdin policies and decide which exits are valid.
    """
    with pathlib.Path(log).open('wb') as stream:
        return subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, **kwargs)


def load_font():
    """{code point: (cells, 16 rows as ints, MSB = leftmost pixel)} from os/Kernel/Unifont.BIN."""
    blob = (ROOT / "os/Kernel/Unifont.BIN").read_bytes()
    (nruns,) = struct.unpack_from("<I", blob)
    font = {}
    for i in range(nruns):
        first, count, off = struct.unpack_from("<III", blob, 4 + 12 * i)
        cells, count = count >> 24, count & 0xFFFFFF
        for k in range(count):
            g = blob[off + k * 16 * cells:off + (k + 1) * 16 * cells]
            font[first + k] = (cells, [int.from_bytes(g[r * cells:(r + 1) * cells], "big") for r in range(16)])
    return font


def draw_text(font, text, cols):
    """Rows of pixel bits (True = foreground) for one text line, padded with blanks to cols cells."""
    rows = [[] for _ in range(16)]
    n = 0
    for ch in text:
        cells, g = font[ord(ch)]
        for r in range(16):
            rows[r] += [bool(g[r] >> (8 * cells - 1 - x) & 1) for x in range(8 * cells)]
        n += cells
    for r in range(16):
        rows[r] += [False] * (8 * (cols - n))
    return rows


def read_png(path):
    png = path.read_bytes()
    assert png.startswith(b"\x89PNG\r\n\x1a\n"), "not a PNG"
    pos, idat = 8, bytearray()
    width = height = None
    while pos < len(png):
        n = int.from_bytes(png[pos:pos + 4], "big")
        kind = png[pos + 4:pos + 8]
        data = png[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", data)
            assert (depth, color, interlace) == (8, 2, 0), "unexpected PNG format"
        if kind == b"IDAT":
            idat.extend(data)
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = width * 3
    rows, prev, pos = [], bytearray(stride), 0
    for _ in range(height):
        filt = raw[pos]
        pos += 1
        row = bytearray(raw[pos:pos + stride])
        pos += stride
        for i in range(stride):
            a = row[i - 3] if i >= 3 else 0
            b = prev[i]
            c = prev[i - 3] if i >= 3 else 0
            if filt == 1:
                row[i] = (row[i] + a) & 255
            elif filt == 2:
                row[i] = (row[i] + b) & 255
            elif filt == 3:
                row[i] = (row[i] + (a + b) // 2) & 255
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
            else:
                assert filt == 0
        rows.append(row)
        prev = row
    return width, height, rows


def screen_of(d, name):
    width, height, rows = read_png(d / name)
    assert (width, height) == (W, H), f"screenshot is {width}x{height}"

    def px(x, y):
        return tuple(rows[y][3 * x:3 * x + 3])

    return px


def text_row_matches(px, font, r, text):
    """Is text row r (16 pixels tall) exactly the Unifont rendering of text, blank after it?"""
    return all(px(x, r * 16 + y) == ((255, 255, 255) if on else (0, 0, 0))
               for y, bits in enumerate(draw_text(font, text, W // 8)) for x, on in enumerate(bits))


def pixel_difference(first, second):
    """Count unequal RGB pixels in equally sized decoded PNGs."""
    assert first[:2] == second[:2], f'image sizes differ: {first[:2]} {second[:2]}'
    width, height = first[:2]
    differ = sum(1 for a, b in zip(first[2], second[2]) if a != b for x in range(width)
                 if a[3 * x:3 * x + 3] != b[3 * x:3 * x + 3])
    return differ, differ / (width * height)
