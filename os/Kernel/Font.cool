// Console font: GNU Unifont (https://unifoundry.com/unifont/, licence in
// Unifont-LICENSE.txt), converted at build time by tools/mkfont.py into
// Unifont.BIN, which FontData.S embeds after the kernel module. Cells are 8x16
// pixels; a glyph takes one cell (ASCII, Latin, ...) or two (Hangul, CJK,
// fullwidth forms) exactly where Utf8Width() says it takes one or two columns.
// The blob layout is described in tools/mkfont.py.
import U8 *ArchFontData();

#define FONT_CELL_W 8
#define FONT_CELL_H 16

U8 *FontGlyph(I64 cp, I64 *_cells)
{//The glyph of a code point: 16 rows of 1 byte (*_cells = 1) or 2 bytes, MSB = leftmost pixel. NULL if the font has none.
    U8 *blob = ArchFontData, *run;
    I64 n = *blob(U32i *), i, first, cnt;
    for (i = 0; i < n; i++) {
        run = blob + 4 + i * 12;
        first = *run(U32i *);
        cnt = *(run + 4)(U32i *);
        if (cp >= first && cp < first + (cnt & 0xFFFFFF)) {
            *_cells = cnt >> 24;
            return blob + *(run + 8)(U32i *) + (cp - first) * 16 * *_cells;
        }
    }
    return NULL;
}
