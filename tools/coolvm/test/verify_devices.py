#!/usr/bin/env python3
"""Verify the headless device guest's framebuffer, disk and generated FDT."""
import pathlib
import re
import struct
import sys
import zlib

out = pathlib.Path(sys.argv[1])
png = (out / "screen.png").read_bytes()
assert png.startswith(b"\x89PNG\r\n\x1a\n")
pos = 8
idat = bytearray()
while pos < len(png):
    n = int.from_bytes(png[pos:pos + 4], "big")
    kind = png[pos + 4:pos + 8]
    data = png[pos + 8:pos + 8 + n]
    assert zlib.crc32(kind + data) == int.from_bytes(png[pos + 8 + n:pos + 12 + n], "big")
    if kind == b"IHDR":
        width, height, depth, color, compression, filter_method, interlace = struct.unpack(">IIBBBBB", data)
        assert (width, height, depth, color, compression, filter_method, interlace) == (64, 32, 8, 2, 0, 0, 0)
    if kind == b"IDAT":
        idat.extend(data)
    pos += 12 + n
raw = zlib.decompress(idat)
stride = width * 3
rows = []
previous = bytearray(stride)
pos = 0
for _ in range(height):
    filt = raw[pos]
    pos += 1
    row = bytearray(raw[pos:pos + stride])
    pos += stride
    for i in range(stride):
        a = row[i - 3] if i >= 3 else 0
        b = previous[i]
        c = previous[i - 3] if i >= 3 else 0
        if filt == 1:
            row[i] = (row[i] + a) & 255
        elif filt == 2:
            row[i] = (row[i] + b) & 255
        elif filt == 3:
            row[i] = (row[i] + (a + b) // 2) & 255
        elif filt == 4:
            p = a + b - c
            d = (abs(p - a), abs(p - b), abs(p - c))
            row[i] = (row[i] + (a if d[0] <= d[1] and d[0] <= d[2] else b if d[1] <= d[2] else c)) & 255
        else:
            assert filt == 0
    rows.append(row)
    previous = row
assert bytes(rows[0][:6]) == b"\xff\x00\x00\x00\xff\x00", "framebuffer pixels differ"
assert bytes(rows[0][6:9]) == b"\x00\x00\x00"

disk = (out / "device-disk.img").read_bytes()
assert disk[:4] == b"ABCD"
assert disk[512:529] == b"coolvm disk write"
assert disk[529:1024] == bytes(495)
assert disk[1024:] == bytes(len(disk) - 1024)
second = (out / "second-disk.img").read_bytes()
assert second == b"WXYZ" + bytes(4092)

dts = (out / "devices.dts").read_text()
for name, pattern in {
    "framebuffer": r"framebuffer@900000000\s*\{[^}]*compatible = \"apple,simple-framebuffer\", \"simple-framebuffer\";[^}]*reg = <0x09 0x00 0x00 0x2000>;[^}]*width = <0x40>;[^}]*height = <0x20>;[^}]*stride = <0x100>;[^}]*format = \"x8r8g8b8\";",
    "input": r"input@1ff001000\s*\{[^}]*compatible = \"coolcom,coolvm-input\";[^}]*reg = <0x01 0xff001000 0x00 0x1000>;[^}]*interrupts = <0x00 0x2bc 0x04>;",
    "disk": r"virtio_mmio@1ff010000\s*\{[^}]*compatible = \"virtio,mmio\";[^}]*reg = <0x01 0xff010000 0x00 0x1000>;[^}]*interrupts = <0x00 0x2c0 0x04>;",
    "second disk": r"virtio_mmio@1ff011000\s*\{[^}]*compatible = \"virtio,mmio\";[^}]*reg = <0x01 0xff011000 0x00 0x1000>;[^}]*interrupts = <0x00 0x2c1 0x04>;",
    "reserved framebuffer": r"reserved-memory\s*\{.*?framebuffer@900000000\s*\{[^}]*no-map;",
}.items():
    assert re.search(pattern, dts, re.S), name
print("device screenshot pixels, disk contents and FDT: OK")
