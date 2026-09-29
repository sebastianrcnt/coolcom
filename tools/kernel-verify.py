#!/usr/bin/env python3
"""Host side of `make test` for the kernel's VM devices (see os/Kernel/DevTest.HC).

  kernel-verify.py prepare DIR   write DIR/disk.img, DIR/fat.img and DIR/input.txt for coolvm
  kernel-verify.py verify DIR    check DIR/screen.png (640x480), DIR/disk.img and DIR/fat.img afterwards
  kernel-verify.py verify-shell DIR   check DIR/shell.png from a boot fed DIR/shell.in on the UART

Disk: 128 sectors, sector s byte j = (s*31 + j*7) & 255. The kernel overwrites
sectors 9 and 10 with byte j (0..1023) = (j*3 + 17) & 255.
FAT: a 40 MiB FAT32 volume made by newfs_msdos (512-byte clusters) holding
HostNote.txt and Test.HC, copied in with mtools (the shell #includes Test.HC). The kernel reads it and writes
FromCoolcom.txt and Sub/Inner.TXT (os/Kernel/DevTest.HC DevTestFs); afterwards
mtools must read them back and fsck_msdos must find the volume clean.
Input: mouse +5,-3, wheel +2, left button down, then the keys
h x BACKSPACE i LSHIFT+a ENTER, which GetStr turns into "hiA", then the
SHELL lines (the shell's output is checked by kernel-test.sh). A BREAK entry is
"delay MS" then Ctrl+Alt+C, typed once the shell is running the line before it.
Shell UART: a plain shell boot is fed a Korean line (UTF-8, with a Hangul typed and deleted
by DEL): the screenshot must show it echoed and then printed, as Unifont wide glyphs.
Screen: rows 0..4 of Unifont text (8x16 cells, wide glyphs two cells, white on
black; row 4 has Hangul and CJK), color bars at y=112, a gray ramp at y=160.
The glyphs come from os/Kernel/Unifont.BIN (layout in tools/mkfont.py).
"""
import pathlib
import re
import struct
import subprocess
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

# Typed into the kernel's shell after the "hiA" line: it must print 49, then two
# statements that never finish are broken out of with Ctrl+Alt+C (a busy loop
# is interrupted in place; Sleep has the shell switched out), then it prints 51.
# Line editing: a line typed as ...7);, Left twice, Backspace, "42" must print 42
# (edits at the cursor), then Up twice and ENTER recalls the 51 line and prints 51 again.
BREAK = ("delay", 2000)
BREAK2 = ("delay", 500)
ENTER = 28
KEY_BACKSPACE, KEY_UP, KEY_LEFT = 14, 103, 105
SHELL = ['I64 Sq(I64 x) { return x * x; }', r'Print("%d\n", Sq(7));',
         'while (TRUE) {}', BREAK, 'Sleep(60000);', BREAK2, r'Print("%d\n", 51);',
         ("text", r'Print("%d\n", 7);'), ("key", KEY_LEFT), ("key", KEY_LEFT), ("key", KEY_BACKSPACE),
         ("text", "42"), ("key", ENTER),
         ("key", KEY_UP), ("key", KEY_UP), ("key", ENTER),
         '#include "Test.HC"', r'Print("%d\n", Tripled(21));', r"""Print("%s%d\n", "\101", '\101' + '\e');"""]

# One shell regression exercises all three protections and prompt recovery.
SHELL += [
    'U8 *over = MAlloc(13); over[13] ^= 1; Free(over);',
    'over[13] ^= 1; Free(over);',
    r'Print("MEMSAFE START\n");',
    'Deep(0); MaskDeep;',
    'U8 *text = &StrLen; *text = 0;',
    r'Print("MEMSAFE RECOVERED %d\n", Sq(9));',
]

# US layout, Linux key codes, as in os/Kernel/Input.HC: char -> (code, shifted).
KEYS = {" ": (57, False), "`": (41, False), "~": (41, True), "\\": (43, False), "|": (43, True)}
for first, lo, up in ((2, "1234567890-=", "!@#$%^&*()_+"), (16, "qwertyuiop[]", "QWERTYUIOP{}"),
                      (30, "asdfghjkl;'", 'ASDFGHJKL:"'), (44, "zxcvbnm,./", "ZXCVBNM<>?")):
    for i, (a, b) in enumerate(zip(lo, up)):
        KEYS[a] = (first + i, False)
        KEYS[b] = (first + i, True)
LSHIFT, ENTER = 42, 28
LCTRL, LALT, KEY_C = 29, 56, 46
SHELL_KO_IN = ('Print("한글 테스트 마\x7f\\n");\r').encode()  # the Hangul 마 is deleted again
SCREEN_KO = "한글 테스트 漢字 Ünï"  # printed by DevTestScreen


def keys_of(code):
    return f"1 {code} 1\n1 {code} 0\n"


def typed(line, enter=True):
    """Input records that type line, then ENTER."""
    out = []
    for ch in line:
        code, shift = KEYS[ch]
        keys = [LSHIFT, code] if shift else [code]
        out += [f"1 {k} 1" for k in keys] + [f"1 {k} 0" for k in reversed(keys)]
    if enter:
        out += [f"1 {ENTER} 1", f"1 {ENTER} 0"]
    return "".join(r + "\n" for r in out)


def sector(s):
    return bytes((s * 31 + j * 7) & 255 for j in range(512))


FAT_SECTORS = 81920
HOST_NOTE = b"Hello from the host\n"
TEST_HC = b"// #include'd by the shell test\nI64 Tripled(I64 x)\n{\n    return 3 * x;\n}\n"
TEST_HC += (b"I64 Deep(I64 n) { U8 pad[1024]; MemSet(pad, n, 1024); return Deep(n+1)+pad[0]; }\n"
            b"U0 MaskDeep() { ArchIrqOff; Deep(0); }\n")


def fs_data(n, seed):
    """DevTestFsData: printable test file contents."""
    return bytes(10 if j % 64 == 63 else 65 + (j * 7 + seed) % 26 for j in range(n))


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)


def prepare_fat(d):
    img = d / "fat.img"
    with open(img, "wb") as f:
        f.truncate(FAT_SECTORS * 512)
    run("newfs_msdos", "-F", "32", "-S", "512", "-c", "1", "-s", str(FAT_SECTORS), "-h", "16", "-u", "63",
        "-v", "COOLFAT", str(img))
    (d / "note.txt").write_bytes(HOST_NOTE)
    run("mcopy", "-i", str(img), str(d / "note.txt"), "::HostNote.txt")
    (d / "Test.HC").write_bytes(TEST_HC)
    run("mcopy", "-i", str(img), str(d / "Test.HC"), "::Test.HC")


def verify_fat(d):
    img = str(d / "fat.img")
    fsck = subprocess.run(["fsck_msdos", "-n", img], capture_output=True, text=True)
    assert fsck.returncode == 0 and "Fix?" not in fsck.stdout, "fsck_msdos:\n" + fsck.stdout + fsck.stderr
    listing = run("mdir", "-i", img, "-/", "-b", "::", text=True).stdout.split()
    for name, want in (("HostNote.txt", HOST_NOTE), ("FromCoolcom.txt", fs_data(3000, 0)),
                       ("Sub/Inner.TXT", fs_data(700, 5))):
        assert "::/" + name in listing, f"{name} not in the host's listing {listing}"
        got = run("mcopy", "-n", "-i", img, "::" + name, "-").stdout
        assert got == want, f"{name} on the FAT volume differs"


def prepare(d):
    (d / "disk.img").write_bytes(b"".join(sector(s) for s in range(SECTORS)))
    prepare_fat(d)
    text = INPUT
    for line in SHELL:
        if isinstance(line, tuple) and line[0] == "text":
            text += typed(line[1], enter=False)
        elif isinstance(line, tuple) and line[0] == "key":
            text += keys_of(line[1])
        elif isinstance(line, tuple):  # Ctrl+Alt+C after a delay
            text += f"delay {line[1]}\n"
            keys = [LCTRL, LALT, KEY_C]
            text += "".join(f"1 {k} 1\n" for k in keys) + "".join(f"1 {k} 0\n" for k in reversed(keys))
        else:
            text += typed(line)
    (d / "input.txt").write_text(text)
    (d / "shell.in").write_bytes(SHELL_KO_IN)


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


def verify_shell(d):
    px, font = screen_of(d, "shell.png"), load_font()
    echo, out = '> Print("한글 테스트 \\n");', "한글 테스트"
    hits = [r for r in range(H // 16 - 1)
            if text_row_matches(px, font, r, echo) and text_row_matches(px, font, r + 1, out)]
    assert len(hits) == 1, f"the typed Korean line and its output are not on the shell screen (matches: {hits})"
    print("kernel-verify: Korean line typed at the shell shows Hangul in the screenshot")


def verify(d):
    px, font = screen_of(d, "screen.png"), load_font()

    lines = [
        "COOLCOM FB TEST",
        "input: hiA",
        f"mouse: x={W // 2 + 5} y={H // 2 - 3} b=1",
        "0123456789 ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz",
        SCREEN_KO,
    ]
    for r, text in enumerate(lines):
        assert text_row_matches(px, font, r, text), f"text row {r} {text!r} is not on the screen"
    for x0, color in ((16, (255, 0, 0)), (64, (0, 255, 0)), (112, (0, 0, 255))):
        for y in (112, 127, 143):
            for x in (x0, x0 + 31):
                assert px(x, y) == color, f"bar at ({x},{y}) is {px(x, y)}, want {color}"
        assert px(x0 + 32, 127) == (0, 0, 0) and px(x0, 144) == (0, 0, 0)
    for i in range(256):
        for y in (160, 175):
            assert px(16 + i, y) == (i, i, i), f"ramp at {16 + i},{y}"

    disk = (d / "disk.img").read_bytes()
    assert len(disk) == SECTORS * 512
    new = bytes((j * 3 + 17) & 255 for j in range(1024))
    for s in range(SECTORS):
        want = new[(s - 9) * 512:(s - 8) * 512] if s in (9, 10) else sector(s)
        assert disk[s * 512:(s + 1) * 512] == want, f"disk sector {s} differs"
    verify_fat(d)
    print("kernel-verify: screen text/pixels, disk contents and FAT32 files OK")


if __name__ == "__main__" and len(sys.argv) == 3 and sys.argv[1] in ("prepare", "verify", "verify-shell"):
    {"prepare": prepare, "verify": verify, "verify-shell": verify_shell}[sys.argv[1]](pathlib.Path(sys.argv[2]))
else:
    sys.exit(__doc__)
