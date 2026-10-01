#!/usr/bin/env python3
"""Host side of `make test` for the kernel's VM devices (see os/Kernel/DevTest.cool).

  kernel-verify.py prepare DIR   write DIR/disk.img, DIR/fat.img and DIR/input.txt for coolvm
  kernel-verify.py verify DIR    check DIR/screen.png (640x480), DIR/disk.img and DIR/fat.img afterwards
  kernel-verify.py verify-shell DIR   check DIR/shell.png from a boot fed DIR/shell.in on the UART

Disk: 128 sectors, sector s byte j = (s*31 + j*7) & 255. The kernel overwrites
sectors 9 and 10 with byte j (0..1023) = (j*3 + 17) & 255.
FAT: a 40 MiB FAT32 volume made by newfs_msdos (512-byte clusters) holding
HostNote.txt and Test.cool, copied in with mtools (the shell #includes Test.cool). The kernel reads it and writes
FromCoolcom.txt and Sub/Inner.TXT (os/Kernel/DevTest.cool DevTestFs); afterwards
mtools must read them back and fsck_msdos must find the volume clean.
Input: mouse +5,-3, wheel +2, left button down, then the keys
h x BACKSPACE i LSHIFT+a ENTER, which GetStr turns into "hiA", then the
SHELL lines (the shell's output is checked by kernel-test.sh). A BREAK entry is
"wait <the line before>" (coolvm waits for the shell's echo of it), "delay MS",
then Ctrl+Alt+C, so a slow boot cannot make a break arrive early.
Shell UART: a plain shell boot is fed a Korean line (UTF-8, with a Hangul typed and deleted
by DEL): the screenshot must show it echoed and then printed, as Unifont wide glyphs.
Screen: rows 0..4 of Unifont text (8x16 cells, wide glyphs two cells, white on
black; row 4 has Hangul and CJK), color bars at y=112, a gray ramp at y=160.
The glyphs come from os/Kernel/Unifont.BIN (layout in tools/mkfont.py).
"""
from testvm import keys_of, typed_line as typed
from testvm import draw_text, load_font, read_png, screen_of, text_row_matches
import pathlib
import re
import struct
import subprocess
import sys

import testvm
from testvm import ROOT

SECTORS = 128
W, H = 640, 480

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
         '#include "Test.cool"', r'Print("%d\n", Tripled(21));', r"""Print("%s%d\n", "\101", '\101' + '\e');""", 'I64 bad = ;']  # a compile error prints ERROR, the line and a caret

# One shell regression exercises all three protections and prompt recovery.
SHELL += [
    'U8 *over = MAlloc(13); over[13] ^= 1; Free(over);',
    'over[13] ^= 1; Free(over);',
    r'Print("MEMSAFE START\n");',
    'Deep(0); MaskDeep;',
    'U8 *text = &StrLen; *text = 0;',
    r'Print("MEMSAFE RECOVERED %d\n", Sq(9));',
]

LSHIFT, ENTER = 42, 28
LCTRL, LALT, KEY_C = 29, 56, 46
SHELL_KO_IN = ('Print("한글 테스트 마\x7f\\n");\r').encode()  # the Hangul 마 is deleted again
SCREEN_KO = "한글 테스트 漢字 Ünï"  # printed by DevTestScreen


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
    testvm.create_disk(img, FAT_SECTORS * 512, label='COOLFAT', cluster_size=512, capture_output=True)
    (d / "note.txt").write_bytes(HOST_NOTE)
    run("mcopy", "-i", str(img), str(d / "note.txt"), "::HostNote.txt")
    for name in ("Host-long-name-" + "h" * (251-15) + ".txt", "호스트에서 만든 긴 한글 파일 이름입니다.txt"):
        run("mcopy", "-i", str(img), str(d / "note.txt"), "::" + name)
    (d / "Test.cool").write_bytes(TEST_HC)
    run("mcopy", "-i", str(img), str(d / "Test.cool"), "::Test.cool")


def verify_fat(d):
    img = str(d / "fat.img")
    fsck = subprocess.run(["fsck_msdos", "-n", img], capture_output=True, text=True)
    assert fsck.returncode == 0 and "Fix?" not in fsck.stdout, "fsck_msdos:\n" + fsck.stdout + fsck.stderr
    listing = run("mdir", "-i", img, "-/", "-b", "::", text=True).stdout.splitlines()
    for name, want in (("HostNote.txt", HOST_NOTE), ("FromCoolcom.txt", fs_data(3000, 0)),
                       ("Sub/Inner.TXT", fs_data(700, 5)),
                       ("k"*251+".txt", b"long"),
                       ("한"*251+".txt", b"wide"),
                       ("커널에서 만든 긴 한글 파일 이름입니다.txt", b"hangul"),
                       ("같은 이름 접두사 첫번째.txt", b"one"),
                       ("같은 이름 접두사 두번째.txt", b"two")):

        assert "::/" + name in listing, f"{name} not in the host's listing {listing}"
        got = run("mcopy", "-n", "-i", img, "::" + name, "-").stdout
        assert got == want, f"{name} on the FAT volume differs"


    # mtools currently truncates supplementary-plane names on this host. Inspect
    # their actual UTF-16 slots and read data using the unique short alias.
    names = fat_directory_names(d / "fat.img")
    alias = names["Unicode-😀-surrogate-pair.txt"]
    assert run("mcopy", "-i", img, "::"+alias, "-").stdout == b"emoji"
    formatted = str(d / "format.img")
    check = run("fsck_msdos", "-n", formatted, text=True)
    assert "Fix?" not in check.stdout, check.stdout
    deep = "Moved/" + "깊은폴더/"*20 + "긴 파일 이름과 한글 내용을 가진 파일.txt"
    assert run("mcopy", "-i", formatted, "::"+deep, "-").stdout == b"tree-data"
    assert run("mcopy", "-i", formatted, "::Broken.txt", "-").stdout == b"broken"
    fat_directory_names(d / "format.img")


def fat_directory_names(path):
    """Independent raw VFAT validation, including aliases and cross-cluster slots."""
    import struct
    image = path.read_bytes()
    u16 = lambda at: struct.unpack_from("<H", image, at)[0]
    u32 = lambda at: struct.unpack_from("<I", image, at)[0]
    spc, reserved, fats = image[13], u16(14), image[16]
    fat_size = u32(36)
    fat = image[reserved*512:(reserved+fat_size)*512]
    data = (reserved+fats*fat_size)*512
    visited = set()
    result = {}
    def directory(first, prefix=""):
        contents = b""
        c = first
        while 2 <= c < 0x0ffffff8:
            assert c not in visited, "shared/cyclic directory"
            visited.add(c)
            contents += image[data+(c-2)*spc*512:data+(c-1)*spc*512]
            c = struct.unpack_from("<I", fat, c*4)[0] & 0x0fffffff
        aliases, slots = set(), []
        for at in range(0, len(contents), 32):
            e = contents[at:at+32]
            if not e[0]:
                assert not slots, "orphan LFN at end"
                break
            if e[0] == 0xe5:
                assert not slots, "orphan LFN before deleted entry"
                continue
            if e[11] == 15:
                slots.append(e)
                continue
            assert e[:11] not in aliases, "duplicate short alias"
            aliases.add(e[:11])
            short = e[:8].decode("ascii").rstrip()
            ext = e[8:11].decode("ascii").rstrip()
            if ext: short += "."+ext
            name = short
            if slots:
                checksum = 0
                for ch in e[:11]: checksum = (((checksum & 1) << 7)+(checksum >> 1)+ch) & 255
                assert 1 <= len(slots) <= 20
                for i, slot in enumerate(slots):
                    assert slot[0] == (len(slots)-i | (0x40 if i == 0 else 0))
                    assert slot[12] == 0 and slot[13] == checksum and slot[26:28] == b"\0\0"
                wide = b"".join(t[1:11]+t[14:26]+t[28:32] for t in reversed(slots))
                units = list(struct.unpack("<"+"H"*(len(wide)//2), wide))
                if 0 in units:
                    end = units.index(0)
                    assert all(x == 0xffff for x in units[end+1:])
                    units = units[:end]
                assert len(units) <= 255
                name = struct.pack("<"+"H"*len(units), *units).decode("utf-16-le")
                slots = []
            result[prefix+name] = prefix+short
            if e[11] & 16 and name not in (".", ".."):
                child = struct.unpack_from("<H",e,26)[0] | struct.unpack_from("<H",e,20)[0] << 16
                directory(child,prefix+name+"/")
    directory(u32(44))
    return result


def prepare(d):
    (d / "disk.img").write_bytes(b"".join(sector(s) for s in range(SECTORS)))
    prepare_fat(d)
    testvm.create_disk(d / "format.img", 64 * 1024 * 1024, capture_output=True)
    text = INPUT
    for line in SHELL:
        if isinstance(line, tuple) and line[0] == "text":
            text += typed(line[1], enter=False)
        elif isinstance(line, tuple) and line[0] == "key":
            text += keys_of(line[1])
        elif isinstance(line, tuple):  # Ctrl+Alt+C a delay after the shell echoed the line before
            text += f"wait {last}\ndelay {line[1]}\n"
            keys = [LCTRL, LALT, KEY_C]
            text += "".join(f"1 {k} 1\n" for k in keys) + "".join(f"1 {k} 0\n" for k in reversed(keys))
        else:
            text += typed(line)
            last = line
    (d / "input.txt").write_text(text)
    (d / "shell.in").write_bytes(SHELL_KO_IN)


def verify_shell(d):
    px, font = screen_of(d, "shell.png"), load_font()
    echo, out = 'C:/> Print("한글 테스트 \\n");', "한글 테스트"
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


if __name__ == "__main__":  # tools/key-test.py imports typed() and keys_of()
    if len(sys.argv) == 3 and sys.argv[1] in ("prepare", "verify", "verify-shell"):
        {"prepare": prepare, "verify": verify, "verify-shell": verify_shell}[sys.argv[1]](pathlib.Path(sys.argv[2]))
    else:
        sys.exit(__doc__)
