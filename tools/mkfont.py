#!/usr/bin/env python3
"""Convert the GNU Unifont .hex source into the kernel's console font blob.

Usage: mkfont.py unifont-X.hex os/Kernel/Unifont.BIN     (or `make font`)

Unifont glyphs are 16 rows tall and 8 or 16 pixels wide; a hex line is
"CODEPOINT:HEXROWS" with 32 (8 wide) or 64 (16 wide) hex digits. The console
draws them in 8x16 cells: one cell for the narrow glyphs, two for the wide.
Only the code points in RANGES are kept, and only where the glyph's width
matches Utf8Width() in os/Kernel/Console.HC (the shell's line editing counts
columns with it), so the cursor arithmetic on the UART and on the
framebuffer agree. Combining marks (width 0) are not drawn at all.

Blob layout, little endian, all offsets from the start of the blob:
  U32 nruns
  nruns x { U32 first_cp, U32 count | cells << 24, U32 offset }
  glyph data: per glyph 16 rows; 1 cell = 1 byte per row, 2 cells = 2 bytes per
  row (high byte = left cell). In a row byte, bit 7 is the leftmost pixel.
A run is consecutive code points with the same cell count and contiguous data.
"""
import struct
import sys

RANGES = [
    (0x20, 0x7E),      # ASCII
    (0xA0, 0x24F),     # Latin-1, Latin Extended-A/B
    (0x250, 0x2FF),    # IPA, spacing modifiers
    (0x370, 0x3FF),    # Greek
    (0x400, 0x52F),    # Cyrillic
    (0x1100, 0x11FF),  # Hangul Jamo
    (0x2000, 0x206F),  # General punctuation
    (0x20A0, 0x20CF),  # Currency
    (0x2100, 0x214F),  # Letterlike
    (0x2190, 0x23FF),  # Arrows, math, technical
    (0x2500, 0x25FF),  # Box drawing, blocks, geometric shapes
    (0x2600, 0x26FF),  # Misc symbols
    (0x3000, 0x30FF),  # CJK punctuation, Hiragana, Katakana
    (0x3130, 0x318F),  # Hangul Compatibility Jamo
    (0x4E00, 0x9FFF),  # CJK Unified Ideographs
    (0xAC00, 0xD7A3),  # Hangul Syllables
    (0xF900, 0xFAFF),  # CJK Compatibility Ideographs
    (0xFF01, 0xFF60),  # Fullwidth forms
    (0xFFE0, 0xFFE6),
    (0xFFFD, 0xFFFD),  # replacement character
]


def utf8_width(cp):
    """Mirror of Utf8Width() in os/Kernel/Console.HC."""
    if 0x300 <= cp <= 0x36F or 0x200B <= cp <= 0x200F or 0xFE00 <= cp <= 0xFE0F:
        return 0
    if (0x1100 <= cp <= 0x115F or 0x2E80 <= cp <= 0xA4CF or 0xAC00 <= cp <= 0xD7A3 or
            0xF900 <= cp <= 0xFAFF or 0xFE30 <= cp <= 0xFE6F or 0xFF00 <= cp <= 0xFF60 or
            0xFFE0 <= cp <= 0xFFE6 or 0x20000 <= cp <= 0x3FFFD):
        return 2
    return 1


def load(hex_path):
    """{code point: (cells, 16 or 32 bytes)} for the kept glyphs."""
    glyphs = {}
    for line in open(hex_path):
        line = line.strip()
        if not line:
            continue
        cp_s, data = line.split(":")
        cp = int(cp_s, 16)
        if not any(lo <= cp <= hi for lo, hi in RANGES):
            continue
        assert len(data) in (32, 64), (cp_s, len(data))
        cells = len(data) // 32
        if utf8_width(cp) == cells:
            glyphs[cp] = (cells, bytes.fromhex(data))
    return glyphs


def main(hex_path, out_path):
    glyphs = load(hex_path)
    assert 0x3F in glyphs and 0xAC00 in glyphs and 0x4E00 in glyphs
    runs, data = [], bytearray()
    for cp in sorted(glyphs):
        cells, g = glyphs[cp]
        if runs and runs[-1][0] + runs[-1][1] == cp and runs[-1][2] == cells:
            runs[-1][1] += 1
        else:
            runs.append([cp, 1, cells, len(data)])
        data += g
    base = 4 + 12 * len(runs)
    blob = bytearray(struct.pack("<I", len(runs)))
    for first, count, cells, off in runs:
        blob += struct.pack("<III", first, count | cells << 24, base + off)
    blob += data
    open(out_path, "wb").write(blob)
    print(f"mkfont: {len(glyphs)} glyphs, {len(runs)} runs, {len(blob)} bytes -> {out_path}")


if __name__ == "__main__" and len(sys.argv) == 3:
    main(sys.argv[1], sys.argv[2])
else:
    sys.exit(__doc__)
