// Framebuffer text console on the FDT's simple-framebuffer (32 bits per pixel,
// 0x00RRGGBB), drawn with GNU Unifont (Font.HC): 8x16 cells, wide glyphs take two.
//
// The framebuffer is outside /memory, but on real hardware it lies inside the
// DRAM aperture the boot tables map as Normal write-back. FbMapNC()
// uses the existing 16 KiB page tables and remaps just the framebuffer
// pages as Normal non-cacheable, so the display controller sees every store.
class CFb
{
    U8 *base;
    I64 w, h, stride, cols, rows, cx, cy, fg, bg;
    I64 cur_drawn;             // the cursor block is currently XORed onto the screen
    I64 u8_left, u8_cp;        // UTF-8 sequence being received
    I64 esc, csi_n, csi_val[8], csi_private, bold;
    U8 *saved_pixels, *saved_cw;
    I64 saved_cx, saved_cy, saved_fg, saved_bg, alternate;
    U8 *cw;                    // per cell: 1 = narrow or blank, 2 = left half of a wide glyph, 0 = its right half
};

CFb fb;

#define FB_BLK_SHIFT  25   // level-2 block: 32 MiB
#define FB_PAGE_SHIFT 14   // 16 KiB granule
#define FB_PAGES      2048 // pages per block

U0 FbMapNC(I64 start, I64 size)
{
    I64 addr, *l3, *l2 = ArchL2Table;
    for (addr = start & ~16383; addr < start + size; addr += 16384) {
        l3 = l2[addr >> 25] & ~16383;
        l3[(addr >> 14) & 2047] = 0;
        ArchTlbFlush;
        l3[(addr >> 14) & 2047] = addr | 3 | (2 << 2) | (3 << 8) | (1 << 10);
    }
    ArchTlbFlush;
}

U0 FbFillRect(I64 x, I64 y, I64 w, I64 h, I64 color)
{
    I64 i, j;
    if (x < 0) {
        w += x;
        x = 0;
    }
    if (y < 0) {
        h += y;
        y = 0;
    }
    if (x + w > fb.w)
        w = fb.w - x;
    if (y + h > fb.h)
        h = fb.h - y;
    for (j = y; j < y + h; j++)
        for (i = x; i < x + w; i++)
            *(fb.base + j * fb.stride + i * 4)(U32i *) = color;
}

U0 FbBlit(I64 col, I64 row, U8 *g, I64 cells)
{//Draw a glyph (16 rows of 1 or 2 bytes, MSB = leftmost pixel) into cells cells at text position col,row.
    U8 *p = fb.base + row * FONT_CELL_H * fb.stride + col * FONT_CELL_W * 4;
    I64 y, x, bits, n = cells * FONT_CELL_W;
    for (y = 0; y < FONT_CELL_H; y++) {
        if (cells == 2) {
            bits = (g[0] << 8) | g[1];
            g += 2;
        } else
            bits = *g++;
        for (x = n - 1; x >= 0; x--) {
            if ((bits >> x) & 1)
                *p(U32i *) = fb.fg;
            else
                *p(U32i *) = fb.bg;
            p += 4;
        }
        p += fb.stride - n * 4;
    }
}

U0 FbBlank(I64 col, I64 row)
{//Erase one cell.
    FbFillRect(col * FONT_CELL_W, row * FONT_CELL_H, FONT_CELL_W, FONT_CELL_H, fb.bg);
    fb.cw[row * fb.cols + col] = 1;
}

U0 FbScroll()
{
    I64 band = fb.stride * FONT_CELL_H;
    MemCpy(fb.base, fb.base + band, (fb.rows - 1) * band);
    FbFillRect(0, (fb.rows - 1) * FONT_CELL_H, fb.w, fb.h - (fb.rows - 1) * FONT_CELL_H, fb.bg);
    MemCpy(fb.cw, fb.cw + fb.cols, (fb.rows - 1) * fb.cols);
    MemSet(fb.cw + (fb.rows - 1) * fb.cols, 1, fb.cols);
    fb.cy = fb.rows - 1;
}

U0 FbPutCp(I64 cp)
{//Draw a code point at the cursor and advance by the columns it takes (Utf8Width). Without a
    //glyph it is a '?' in each column.
    I64 w = Utf8Width(cp), cells, i, j;
    U8 *g = NULL;
    if (!w)
        return;
    if (cp < 0x110000)
        g = FontGlyph(cp, &cells);
    if (!g || cells != w) {
        while (w-- > 0)
            FbPutCp('?');
        return;
    }
    if (fb.cx + w > fb.cols) {  // wrap lazily, so a full line followed by \n is one line
        fb.cx = 0;
        fb.cy++;
        if (fb.cy >= fb.rows)
            FbScroll;
    }
    i = fb.cy * fb.cols + fb.cx;
    // Drawing over half of a wide glyph erases the other half.
    if (fb.cx > 0 && !fb.cw[i])
        FbBlank(fb.cx - 1, fb.cy);
    for (j = 0; j < w; j++)
        if (fb.cw[i + j] == 2 && j + 1 >= w && fb.cx + j + 1 < fb.cols)
            FbBlank(fb.cx + j + 1, fb.cy);
    FbBlit(fb.cx, fb.cy, g, w);
    fb.cw[i] = w;
    if (w == 2)
        fb.cw[i + 1] = 0;
    fb.cx += w;
}

U0 FbCursorFlip()
{//XOR the cell under the text cursor (a block cursor, two cells wide over a wide glyph); twice restores it.
    U8 *p;
    I64 x, y, w;
    if (fb.cx >= fb.cols || fb.cy >= fb.rows)
        return;
    w = FONT_CELL_W;
    if (fb.cw[fb.cy * fb.cols + fb.cx] == 2)
        w *= 2;
    p = fb.base + fb.cy * FONT_CELL_H * fb.stride + fb.cx * FONT_CELL_W * 4;
    for (y = 0; y < FONT_CELL_H; y++) {
        for (x = 0; x < w; x++)
            *(p + x * 4)(U32i *) ^= 0xFFFFFF;
        p += fb.stride;
    }
}

U0 FbCursorHide()
{
    if (fb.cur_drawn) {
        FbCursorFlip;
        fb.cur_drawn = FALSE;
    }
}

U0 FbCursorShow()
{
    if (!fb.cur_drawn) {
        FbCursorFlip;
        fb.cur_drawn = TRUE;
    }
}

U0 FbClear()
{
    fb.cur_drawn = FALSE;  // the fill wipes it
    FbFillRect(0, 0, fb.w, fb.h, fb.bg);
    MemSet(fb.cw, 1, fb.cols * fb.rows);
    fb.cx = fb.cy = 0;
    FbCursorShow;
}

I64 FbAnsiColor(I64 n)
{// Standard ANSI palette in 0xRRGGBB.
    switch (n & 15) {
        case 0: return 0x000000;
        case 1: return 0xAA0000;
        case 2: return 0x00AA00;
        case 3: return 0xAA5500;
        case 4: return 0x0000AA;
        case 5: return 0xAA00AA;
        case 6: return 0x00AAAA;
        case 7: return 0xAAAAAA;
        case 8: return 0x555555;
        case 9: return 0xFF5555;
        case 10: return 0x55FF55;
        case 11: return 0xFFFF55;
        case 12: return 0x5555FF;
        case 13: return 0xFF55FF;
        case 14: return 0x55FFFF;
        case 15: return 0xFFFFFF;
    }
    return 0;

}

I64 FbParam(I64 i, I64 def)
{
    if (i > fb.csi_n || !fb.csi_val[i])
        return def;
    return fb.csi_val[i];
}

U0 FbErase(I64 x1, I64 y1, I64 x2, I64 y2)
{
    I64 x, y;
    for (y = y1; y <= y2; y++)
        for (x = x1; x <= x2; x++)
            FbBlank(x, y);
}

U0 FbAlt(Bool on)
{
    I64 bytes = fb.stride * fb.h, cells = fb.cols * fb.rows;
    if (on && !fb.alternate) {
        if (!fb.saved_pixels) {
            fb.saved_pixels = MAlloc(bytes);
            fb.saved_cw = MAlloc(cells);
        }
        MemCpy(fb.saved_pixels, fb.base, bytes);
        MemCpy(fb.saved_cw, fb.cw, cells);
        fb.saved_cx = fb.cx;
        fb.saved_cy = fb.cy;
        fb.saved_fg = fb.fg;
        fb.saved_bg = fb.bg;
        fb.alternate = TRUE;
        FbClear;
    } else if (!on && fb.alternate) {
        MemCpy(fb.base, fb.saved_pixels, bytes);
        MemCpy(fb.cw, fb.saved_cw, cells);
        fb.cx = fb.saved_cx;
        fb.cy = fb.saved_cy;
        fb.fg = fb.saved_fg;
        fb.bg = fb.saved_bg;
        fb.alternate = FALSE;
        fb.cur_drawn = FALSE;
    }
}

U0 FbCsi(U8 c)
{
    I64 i, n = fb.csi_val[0], x, y;
    if (fb.csi_private) {
        if ((c == 'h' || c == 'l') && (n == 1049 || n == 47))
            FbAlt(c == 'h');
        return;
    }
    switch (c) {
        case 'm':
            for (i = 0; i <= fb.csi_n; i++) {
                n = fb.csi_val[i];
                if (!n) {fb.fg = 0xFFFFFF; fb.bg = 0; fb.bold = FALSE;}
                else if (n == 1) fb.bold = TRUE;
                else if (n == 22) fb.bold = FALSE;
                else if (n == 39) fb.fg = 0xFFFFFF;
                else if (n == 49) fb.bg = 0;
                else if (n >= 30 && n <= 37) fb.fg = FbAnsiColor(n - 30 + 8 * fb.bold);
                else if (n >= 40 && n <= 47) fb.bg = FbAnsiColor(n - 40);
                else if (n >= 90 && n <= 97) fb.fg = FbAnsiColor(n - 90 + 8);
                else if (n >= 100 && n <= 107) fb.bg = FbAnsiColor(n - 100 + 8);
            }
            break;
        case 'H': case 'f':
            fb.cy = FbParam(0, 1) - 1;
            fb.cx = FbParam(1, 1) - 1;
            break;
        case 'A': fb.cy -= FbParam(0, 1); break;
        case 'B': fb.cy += FbParam(0, 1); break;
        case 'C': fb.cx += FbParam(0, 1); break;
        case 'D': fb.cx -= FbParam(0, 1); break;
        case 'G': fb.cx = FbParam(0, 1) - 1; break;
        case 'd': fb.cy = FbParam(0, 1) - 1; break;
        case 'J':
            if (n == 2 || n == 3) FbErase(0, 0, fb.cols - 1, fb.rows - 1);
            else if (n == 0) {
                FbErase(fb.cx, fb.cy, fb.cols - 1, fb.cy);
                for (y = fb.cy + 1; y < fb.rows; y++) FbErase(0, y, fb.cols - 1, y);
            } else if (n == 1) {
                for (y = 0; y < fb.cy; y++) FbErase(0, y, fb.cols - 1, y);
                FbErase(0, fb.cy, fb.cx, fb.cy);
            }
            break;
        case 'K':
            x = fb.cx;
            y = fb.cols - 1;
            if (n == 1) {x = 0; y = fb.cx;}
            else if (n == 2) x = 0;
            FbErase(x, fb.cy, y, fb.cy);
            break;
    }
    if (fb.cx < 0) fb.cx = 0;
    if (fb.cx >= fb.cols) fb.cx = fb.cols - 1;
    if (fb.cy < 0) fb.cy = 0;
    if (fb.cy >= fb.rows) fb.cy = fb.rows - 1;
}

U0 FbPutC1(U8 c)
{//Console output: \n \r \b \t are handled, other control codes are ignored. UTF-8 is decoded;
    //a character takes Utf8Width columns, like on a terminal, so \b (one column) matches the
    //shell's line editing, which backs up by columns.
    if (fb.esc == 1) {
        fb.esc = 0;
        if (c == '[') {
            fb.esc = 2;
            fb.csi_n = fb.csi_private = 0;
            MemSet(fb.csi_val, 0, sizeof(fb.csi_val));
        }
        return;
    }
    if (fb.esc == 2) {
        if (c == '?' && !fb.csi_n && !fb.csi_val[0]) fb.csi_private = TRUE;
        else if (c >= '0' && c <= '9') fb.csi_val[fb.csi_n] = fb.csi_val[fb.csi_n] * 10 + c - '0';
        else if (c == ';' && fb.csi_n < 7) fb.csi_n++;
        else {fb.esc = 0; FbCsi(c);}
        return;
    }
    if (c == 27) {fb.esc = 1; fb.u8_left = 0; return;}
    if (c >= 0x80) {
        if (Utf8Len(c) > 1) {
            fb.u8_left = Utf8Len(c) - 1;
            fb.u8_cp = c & (0x7F >> Utf8Len(c));
        } else if (fb.u8_left > 0) {
            fb.u8_cp = (fb.u8_cp << 6) | (c & 0x3F);
            if (!--fb.u8_left)
                FbPutCp(fb.u8_cp);
        }
        return;
    }
    fb.u8_left = 0;
    if (c == '\n') {
        fb.cx = 0;
        fb.cy++;
    } else if (c == '\r')
        fb.cx = 0;
    else if (c == 8) {
        if (fb.cx > 0)
            fb.cx--;
    } else if (c == '\t')
        fb.cx = (fb.cx + 8) & ~7;
    else if (c >= 32 && c < 127)
        FbPutCp(c);
    if (fb.cy >= fb.rows)
        FbScroll;
}

U0 FbPutC(U8 c)
{
    FbCursorHide;
    FbPutC1(c);
    FbCursorShow;
}

Bool FbInit()
{//Map the framebuffer and add it as a console output. FALSE if the FDT has none.
    if (!fdt_fb_32bpp || !fdt_fb.base)
        return FALSE;
    fb.base = fdt_fb.base;
    fb.w = fdt_fb_w;
    fb.h = fdt_fb_h;
    fb.stride = fdt_fb_stride;
    fb.cols = fb.w / FONT_CELL_W;
    fb.rows = fb.h / FONT_CELL_H;
    fb.fg = 0xFFFFFF;
    fb.bg = 0;
    if (fb.cols < 1 || fb.rows < 2 || fb.stride < fb.w * 4)
        return FALSE;
    fb.cw = MAlloc(fb.cols * fb.rows);
    FbMapNC(fdt_fb.base, fb.stride * fb.h);
    FbClear;  // also draws the cursor
    ConsAdd(&FbPutC);
    return TRUE;
}

U0 ConsClear()
{
    if (fb.base)
        FbClear;
}

U0 FbSetColor(I64 fg, I64 bg)
{
    fb.fg = fg;
    fb.bg = bg;
}
