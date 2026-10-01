#ifndef COOLVM_SCROLL_H
#define COOLVM_SCROLL_H
#include <stdbool.h>
#include <math.h>
/* REL_WHEEL/HWHEEL are signed lines. One line = 20 AppKit points.
 * AppKit precise deltas are in view points: convert both delta and line height
 * to backing pixels, so Retina does not double the scrolling speed.
 * Keep sub-line remainders across ended -> momentum began/changed -> ended.
 * Cancellation (including momentum cancellation) drops only the remainder.
 */
struct scroll_accumulator { double x, y; bool precise, initialized, momentum; };
static inline void scroll_lines(struct scroll_accumulator *s, double x, double y,
                                bool precise, double backing_scale,
                                bool cancelled, bool momentum, int *hx, int *vy)
{
    *hx = *vy = 0;
    if (cancelled) { s->x = s->y = 0; s->momentum = false; return; }
    if (s->initialized && precise != s->precise) s->x = s->y = 0;
    s->initialized = true; s->precise = precise; s->momentum = momentum;
    if (!isfinite(x) || !isfinite(y)) return;
    if (precise) {
        if (!isfinite(backing_scale) || backing_scale <= 0) backing_scale = 1;
        double pixels_per_line = 20 * backing_scale;
        x = x * backing_scale / pixels_per_line;
        y = y * backing_scale / pixels_per_line;
    }
    s->x += x; s->y += y;
    /* Bound conversion for malformed/synthetic events, retaining normal input. */
    double rx = round(s->x), ry = round(s->y);
    if (fabs(s->x - rx) < 1e-12) s->x = rx;
    if (fabs(s->y - ry) < 1e-12) s->y = ry;
    double ix = trunc(s->x), iy = trunc(s->y);
    if (ix > 32767) ix = 32767; if (ix < -32767) ix = -32767;
    if (iy > 32767) iy = 32767; if (iy < -32767) iy = -32767;
    *hx = (int)ix; *vy = (int)iy; s->x -= ix; s->y -= iy;
}
#endif
