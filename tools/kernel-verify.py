#!/usr/bin/env python3
"""Host side of `make test` for the kernel's VM devices (see os/Kernel/DevTest.HC).

  kernel-verify.py prepare DIR   write DIR/disk.img and DIR/input.txt for coolvm
  kernel-verify.py verify DIR    check DIR/screen.png (640x480) and DIR/disk.img afterwards

Disk: 128 sectors, sector s byte j = (s*31 + j*7) & 255. The kernel overwrites
sectors 9 and 10 with byte j (0..1023) = (j*3 + 17) & 255.
Input: mouse +5,-3, wheel +2, left button down, then the keys
h x BACKSPACE i LSHIFT+a ENTER, which GetStr turns into "hiA".
Screen: rows 0..3 of 8x8 TempleOS-font text (white on black), color bars at
y=80, a gray ramp at y=128.
"""
import pathlib
import re
import struct
import sys
import zlib

SECTORS = 128
W, H = 640, 480
ROOT = pathlib.Path(__file__).resolve().parent.parent

INPUT = """# mouse
2 0 5
2 1 -3
2 8 2
1 272 1
# h x BACKSPACE i
1 35 1
1 35 0
1 45 1
1 45 0
1 14 1
1 14 0
1 23 1
1 23 0
# LSHIFT a
1 42 1
1 30 1
1 30 0
1 42 0
# ENTER
1 28 1
1 28 0
"""


def sector(s):
    return bytes((s * 31 + j * 7) & 255 for j in range(512))


def prepare(d):
    (d / "disk.img").write_bytes(b"".join(sector(s) for s in range(SECTORS)))
    (d / "input.txt").write_text(INPUT)


def load_font():
    text = (ROOT / "boot/uefi-probe/font8x8.h").read_text()
    vals = [int(v, 16) for v in re.findall(r"0x([0-9A-Fa-f]{16})ULL", text)]
    assert len(vals) == 256
    return vals


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


def verify(d):
    width, height, rows = read_png(d / "screen.png")
    assert (width, height) == (W, H), f"screenshot is {width}x{height}"
    font = load_font()

    def px(x, y):
        return tuple(rows[y][3 * x:3 * x + 3])

    lines = [
        "COOLCOM FB TEST",
        "input: hiA",
        f"mouse: x={W // 2 + 5} y={H // 2 - 3} b=1",
        "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz",
    ]
    for r, text in enumerate(lines):
        text = text.ljust(W // 8)
        for col, ch in enumerate(text):
            glyph = font[ord(ch)]
            for y in range(8):
                bits = (glyph >> (8 * y)) & 255
                for x in range(8):
                    want = (255, 255, 255) if (bits >> x) & 1 else (0, 0, 0)
                    got = px(col * 8 + x, r * 8 + y)
                    assert got == want, f"text row {r} {text.strip()!r}: pixel ({col * 8 + x},{r * 8 + y}) is {got}, want {want}"
    for x0, color in ((16, (255, 0, 0)), (64, (0, 255, 0)), (112, (0, 0, 255))):
        for y in (80, 95, 111):
            for x in (x0, x0 + 31):
                assert px(x, y) == color, f"bar at ({x},{y}) is {px(x, y)}, want {color}"
        assert px(x0 + 32, 95) == (0, 0, 0) and px(x0, 112) == (0, 0, 0)
    for i in range(256):
        for y in (128, 143):
            assert px(16 + i, y) == (i, i, i), f"ramp at {16 + i},{y}"

    disk = (d / "disk.img").read_bytes()
    assert len(disk) == SECTORS * 512
    new = bytes((j * 3 + 17) & 255 for j in range(1024))
    for s in range(SECTORS):
        want = new[(s - 9) * 512:(s - 8) * 512] if s in (9, 10) else sector(s)
        assert disk[s * 512:(s + 1) * 512] == want, f"disk sector {s} differs"
    print("kernel-verify: screen text/pixels and disk contents OK")


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] in ("prepare", "verify"):
    {"prepare": prepare, "verify": verify}[sys.argv[1]](pathlib.Path(sys.argv[2]))
else:
    sys.exit(__doc__)
