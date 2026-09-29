#!/usr/bin/env python3
"""Make a real-hardware boot payload: m1n1 with our kernel appended.

    m1n1-payload.py m1n1.bin t8103-j274.dtb kernel.Image out.bin [--bootargs STR]

Layout (docs/m1-platform.md section 2.2, m1n1:src/payload.c):
    m1n1.bin || [chosen.bootargs=STR\\n] || DTB || gzip(Image) || 8 zero bytes
m1n1 scans the payloads after its own image: a `name=value\\n` variable, an FDT
(used when its root compatible holds apple,<target-type>, apple,j274 on the
Mac mini), then the gzip stream, whose content it re-scans and recognises as
a kernel by "ARM\\x64" at 0x38. The gzip form (as Asahi ships Image.gz) gives
m1n1 the stream's size, so scanning continues after it and stops at the zero
word. After writing, the file is parsed back the same way and checked.
"""
import gzip
import struct
import sys
import zlib

FDT_MAGIC = 0xD00DFEED


def fdt_root_compatible(dtb):
    """The root node's compatible strings."""
    magic, total, off_struct, off_strings = struct.unpack(">IIII", dtb[:16])
    assert magic == FDT_MAGIC, "not a devicetree blob"
    p, depth = off_struct, 0
    while True:
        tok = struct.unpack(">I", dtb[p:p + 4])[0]
        p += 4
        if tok == 1:  # FDT_BEGIN_NODE: name, NUL, pad to 4
            depth += 1
            p = (dtb.index(b"\0", p) + 4) & ~3
        elif tok == 2:  # FDT_END_NODE
            depth -= 1
        elif tok == 3:  # FDT_PROP
            size, nameoff = struct.unpack(">II", dtb[p:p + 8])
            p += 8
            name = dtb[off_strings + nameoff:dtb.index(b"\0", off_strings + nameoff)]
            if depth == 1 and name == b"compatible":
                return dtb[p:p + size].rstrip(b"\0").split(b"\0")
            p = (p + size + 3) & ~3
        elif tok == 4:  # FDT_NOP
            pass
        else:
            return []


def check(payload, m1n1, dtb, image, bootargs):
    """Walk the payloads after m1n1 as payload.c does."""
    assert payload.startswith(m1n1)
    # m1n1.bin runs to _payload_start (the end of its 64 KiB-aligned stacks).
    assert len(m1n1) % 0x10000 == 0, "m1n1.bin does not end at _payload_start"
    p = len(m1n1)
    if bootargs is not None:
        line = b"chosen.bootargs=" + bootargs.encode() + b"\n"
        assert payload[p:p + len(line)] == line, "bootargs variable"
        p += len(line)
    magic, total = struct.unpack(">II", payload[p:p + 8])
    assert magic == FDT_MAGIC, "no devicetree after m1n1"
    fdt = payload[p:p + total]
    assert fdt == dtb
    assert b"apple,j274" in fdt_root_compatible(fdt), "DTB root compatible lacks apple,j274"
    p += total
    assert payload[p:p + 2] == b"\x1f\x8b", "no gzip payload after the devicetree"
    z = zlib.decompressobj(31)
    kernel = z.decompress(payload[p:])
    assert z.eof, "truncated gzip payload"
    assert kernel == image
    assert kernel[0x38:0x3C] == b"ARM\x64", "kernel lacks the arm64 Image magic"
    image_size, flags = struct.unpack("<QQ", kernel[0x10:0x20])
    assert len(kernel) <= image_size, "image_size smaller than the Image"
    assert (flags >> 1) & 3 == 2, "Image header does not say 16 KiB pages"
    rest = z.unused_data
    assert rest[:4] == b"\0\0\0\0", "payload list is not terminated"
    return image_size


def main():
    args = sys.argv[1:]
    bootargs = None
    if "--bootargs" in args:
        i = args.index("--bootargs")
        bootargs = args[i + 1]
        del args[i:i + 2]
    if len(args) != 4:
        sys.exit(__doc__)
    m1n1, dtb, image = (open(a, "rb").read() for a in args[:3])
    parts = [m1n1]
    if bootargs is not None:
        parts.append(b"chosen.bootargs=" + bootargs.encode() + b"\n")
    parts += [dtb, gzip.compress(image, 9, mtime=0), b"\0" * 8]
    payload = b"".join(parts)
    image_size = check(payload, m1n1, dtb, image, bootargs)
    open(args[3], "wb").write(payload)
    print("%s: m1n1 %d + DTB %d + Image %d (gzip, image_size %#x) = %d bytes" %
          (args[3], len(m1n1), len(dtb), len(image), image_size, len(payload)))


if __name__ == "__main__":
    main()
