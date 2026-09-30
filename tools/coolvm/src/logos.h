/* Logos (docs/logos.md): coolcom's GPU cell renderer, custom virtio-gpu commands.
 * Every command is a virtio-gpu control header (24 bytes) followed by little-endian
 * 32-bit fields; the first field is the target (0: the scanout; glyphs have none).
 * GRID carries the protocol version; a later version adds command numbers. */
#ifndef COOLVM_LOGOS_H
#define COOLVM_LOGOS_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define LOGOS_FEATURE 23           /* virtio-gpu device feature bit (device-specific range) */
#define LOGOS_VERSION 1            /* FDT "coolcom,logos" on the virtio-gpu node */
#define LOGOS_CMD_GRID    0x4000   /* target, version, width, height (pixels), cols, rows, cell w, cell h */
#define LOGOS_CMD_GLYPH   0x4001   /* id (not 0), cells (1|2), then cells*cw*ch coverage bytes */
#define LOGOS_CMD_ROWS    0x4002   /* target, first row, count, 0, u64 guest address of count*cols cells */
#define LOGOS_CMD_SCROLL  0x4003   /* target, n: rows move up n, the n new bottom rows are blank */
#define LOGOS_CMD_CURSOR  0x4004   /* target, col, row, cells (0: hidden) */
#define LOGOS_CMD_FILL    0x4005   /* target, x, y, w, h, 0xRRGGBB: over the cells, until they are sent again */
#define LOGOS_CMD_PRESENT 0x4006   /* target: the frame is complete */
/* A cell (16 bytes): glyph id (0: none), fg, bg (0xRRGGBB), flags. */
#define LOGOS_BOLD      1
#define LOGOS_REVERSE   2
#define LOGOS_UNDERLINE 4
#define LOGOS_RIGHT     8          /* the right half of a two-cell glyph */
#define LOGOS_CELL_FLAGS 15

bool logos_active(void);
void logos_reset(void);
uint32_t logos_command(uint32_t type, const uint8_t *p, size_t len); /* g.lock held */
bool logos_snapshot(uint8_t **pixels, uint32_t *width, uint32_t *height); /* takes g.lock */
#endif
