#!/usr/bin/env python3
"""Create a TTF-only translation input from unmodified upstream stb_truetype.

Every replacement is asserted against the vendored upstream text. The native
reference uses stbtt_source.c with the original header, not this specialization.
"""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name('stbtt_source.c')
HEADER = ROOT / 'vendor/stb/stb_truetype.h'


def replace_once(text, old, new):
    count = text.count(old)
    if count != 1:
        raise ValueError(f'expected one upstream match, found {count}: {old[:72]!r}')
    return text.replace(old, new, 1)


def main(outdir):
    outdir.mkdir(parents=True, exist_ok=True)
    header = HEADER.read_text()
    begin = header.index('   if (info->glyf) {\n', header.index('static int stbtt_InitFont_internal('))
    end = header.index('\n   t = stbtt__find_table(data, fontstart, "maxp");', begin)
    original = header[begin:end]
    header = replace_once(header, original,
                          '   if (!info->glyf || !info->loca) return 0;')
    header = replace_once(header, '   info->cff = stbtt__new_buf(NULL, 0);',
                          '   info->cff.size = 0;')
    header = replace_once(header,
                          '   if (info->cff.size) {\n      stbtt__GetGlyphInfoT2(info, glyph_index, x0, y0, x1, y1);\n   } else {',
                          '   {')
    header = replace_once(header,
                          '   if (!info->cff.size)\n      return stbtt__GetGlyphShapeTT(info, glyph_index, pvertices);\n   else\n      return stbtt__GetGlyphShapeT2(info, glyph_index, pvertices);',
                          '   return stbtt__GetGlyphShapeTT(info, glyph_index, pvertices);')
    (outdir / 'stbtt_ttf.h').write_text(header)
    source = SOURCE.read_text().replace('#include "../../vendor/stb/stb_truetype.h"',
                                        '#include "stbtt_ttf.h"')
    (outdir / 'stbtt_ttf.c').write_text(source)


if __name__ == '__main__':
    main(Path(sys.argv[1]))
