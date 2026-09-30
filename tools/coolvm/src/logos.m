/* Logos: the terminal cell renderer of coolcom's GPU graphics layer (docs/logos.md).
 *
 * The guest sends a cell grid instead of pixels, over custom commands on the virtio-gpu
 * control queue (feature bit LOGOS_FEATURE, FDT "coolcom,logos"): the grid and cell size,
 * glyphs (8-bit coverage, rasterized by the guest) for an atlas, rows of cells, scrolls,
 * the cursor, filled rectangles, and "frame done". Commands only change the state below
 * (under g.lock). Pixels exist only when something looks: the window (once per changed
 * frame) or a screenshot, which render the whole target in one Metal pass: per pixel, the
 * cell under it, its glyph's coverage from the atlas, fg/bg (reverse, bold, underline,
 * wide cells), the block cursor, and the fill overlay on top.
 *
 * Targets: 0 is the scanout. The command layout keeps a target in every command so that
 * windows (a texture or layer per target) and compositing can be added later. */
#import <Metal/Metal.h>
#include "virtio.h"
#include "logos.h"

#define ATLAS_W 4096
#define ATLAS_H 2048
#define MAP_SIZE 65536 /* glyph id -> slot, open addressing; at most MAP_SIZE / 2 glyphs */

struct lcell { uint32_t slot, fg, bg, flags; }; /* as the shader reads it */

static struct {
    bool active;                 /* target 0 is set up and shown instead of the 2D scanout */
    uint32_t width, height, cols, rows, cw, ch, first;
    struct lcell *cells;         /* rows * cols, physical rows (logical row r is (first + r) % rows) */
    uint32_t cur_col, cur_row, cur_cells;
    uint32_t *overlay;           /* width * height 0xAARRGGBB; grid rows stored like cells (ring) */
    bool overlay_used;
    uint8_t *atlas;              /* ATLAS_W * ATLAS_H coverage */
    uint32_t slot_w, per_row, nslots, max_slots, atlas_dirty0, atlas_dirty1; /* dirty slot rows [0, 1) */
    uint32_t map_key[MAP_SIZE], map_slot[MAP_SIZE];
    uint64_t generation;         /* bumped on every change (redraw only on change) */
} lg;

static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> pipeline;
static id<MTLTexture> atlas_tex, overlay_tex;
static uint32_t overlay_tex_w, overlay_tex_h;

bool logos_active(void) { return lg.active; }

static void changed(void)
{
    lg.generation++;
    atomic_store(&g.fb_damage_used, true);
    atomic_store(&g.fb_damage, 1);
}

void logos_reset(void)
{
    free(lg.cells); free(lg.overlay);
    lg.cells = NULL; lg.overlay = NULL;
    lg.active = false; lg.overlay_used = false;
    lg.nslots = 0; lg.cw = lg.ch = 0;
    memset(lg.map_key, 0, sizeof lg.map_key);
    changed();
}

static uint32_t map_find(uint32_t id, bool insert)
{
    uint32_t h = (id * 2654435761u) & (MAP_SIZE - 1);
    while (lg.map_key[h]) {
        if (lg.map_key[h] == id) return lg.map_slot[h];
        h = (h + 1) & (MAP_SIZE - 1);
    }
    if (!insert || lg.nslots >= lg.max_slots) return 0;
    lg.map_key[h] = id;
    return lg.map_slot[h] = lg.nslots++;
}

static uint32_t *overlay_row(uint32_t y)
{/* Grid pixel rows rotate with the cells, the bottom margin stays put (as the CPU ring). */
    uint32_t grid = lg.rows * lg.ch;
    if (y < grid) y = (y + lg.first * lg.ch) % grid;
    return lg.overlay + (size_t)y * lg.width;
}

static void overlay_clear_cells(uint32_t row, uint32_t count)
{
    if (!lg.overlay_used) return;
    for (uint32_t y = row * lg.ch; y < (row + count) * lg.ch; y++)
        memset(overlay_row(y), 0, lg.cols * lg.cw * 4);
}

static uint32_t grid(const uint8_t *p, size_t len)
{
    if (len < 24 + 32) return 0x1205;
    uint32_t target = vio32(p + 24), version = vio32(p + 28), w = vio32(p + 32), h = vio32(p + 36),
             cols = vio32(p + 40), rows = vio32(p + 44), cw = vio32(p + 48), ch = vio32(p + 52);
    if (version != LOGOS_VERSION) return 0x1200;  /* the guest speaks another protocol */
    if (target || !w || !h || w > 8192 || h > 8192 || !cols || !rows || cw < 4 || ch < 4 ||
        cw > 64 || ch > 128 || cols * cw > w || rows * ch > h)
        return 0x1205;
    if (cw != lg.cw || ch != lg.ch) {  /* a new cell size: a new atlas */
        free(lg.atlas);
        lg.atlas = calloc(ATLAS_W, ATLAS_H);
        if (!lg.atlas) return 0x1201;
        lg.cw = cw; lg.ch = ch; lg.slot_w = 2 * cw;
        lg.per_row = ATLAS_W / lg.slot_w;
        lg.max_slots = lg.per_row * (ATLAS_H / ch);
        if (lg.max_slots > MAP_SIZE / 2) lg.max_slots = MAP_SIZE / 2;
        memset(lg.map_key, 0, sizeof lg.map_key);
        lg.nslots = 1;  /* slot 0: blank */
        lg.atlas_dirty0 = 0; lg.atlas_dirty1 = ATLAS_H / ch;
    }
    struct lcell *cells = calloc((size_t)cols * rows, sizeof *cells);
    uint32_t *overlay = calloc((size_t)w * h, 4);
    if (!cells || !overlay) { free(cells); free(overlay); return 0x1201; }
    free(lg.cells); free(lg.overlay);
    lg.cells = cells; lg.overlay = overlay; lg.overlay_used = false;
    lg.width = w; lg.height = h; lg.cols = cols; lg.rows = rows; lg.first = 0;
    lg.cur_cells = 0; lg.active = true;
    changed();
    return 0x1100;
}

static uint32_t glyph(const uint8_t *p, size_t len)
{
    if (!lg.cells || len < 24 + 8) return 0x1205;
    uint32_t id = vio32(p + 24), cells = vio32(p + 28), w = cells * lg.cw;
    if (!id || (cells != 1 && cells != 2) || len < 32 + (size_t)w * lg.ch) return 0x1205;
    uint32_t slot = map_find(id, true);
    if (!slot) return 0x1201;
    uint32_t sx = slot % lg.per_row * lg.slot_w, sy = slot / lg.per_row * lg.ch;
    for (uint32_t y = 0; y < lg.ch; y++) {
        uint8_t *dst = lg.atlas + (size_t)(sy + y) * ATLAS_W + sx;
        memcpy(dst, p + 32 + y * w, w);
        if (w < lg.slot_w) memset(dst + w, 0, lg.slot_w - w);
    }
    uint32_t srow = slot / lg.per_row;
    if (lg.atlas_dirty0 >= lg.atlas_dirty1) { lg.atlas_dirty0 = srow; lg.atlas_dirty1 = srow + 1; }
    else {
        if (srow < lg.atlas_dirty0) lg.atlas_dirty0 = srow;
        if (srow + 1 > lg.atlas_dirty1) lg.atlas_dirty1 = srow + 1;
    }
    return 0x1100;
}

static uint32_t rows_cmd(const uint8_t *p, size_t len)
{
    if (!lg.cells || len < 24 + 24 || vio32(p + 24)) return 0x1205;
    uint32_t row = vio32(p + 28), count = vio32(p + 32);
    uint64_t addr = vio64(p + 40);
    if (!count || row >= lg.rows || count > lg.rows - row) return 0x1205;
    const uint8_t *src = virtio_guest(addr, (uint64_t)count * lg.cols * 16);
    if (!src) return 0x1205;
    for (uint32_t r = 0; r < count; r++) {
        struct lcell *dst = lg.cells + (size_t)((lg.first + row + r) % lg.rows) * lg.cols;
        for (uint32_t c = 0; c < lg.cols; c++, src += 16) {
            uint32_t id = vio32(src);
            dst[c].slot = id ? map_find(id, false) : 0;
            dst[c].fg = vio32(src + 4) & 0xffffff;
            dst[c].bg = vio32(src + 8) & 0xffffff;
            dst[c].flags = vio32(src + 12) & LOGOS_CELL_FLAGS;
        }
    }
    overlay_clear_cells(row, count);  /* text drawn again shows over a filled rectangle */
    return 0x1100;
}

static uint32_t scroll(const uint8_t *p, size_t len)
{
    if (!lg.cells || len < 24 + 8 || vio32(p + 24)) return 0x1205;
    uint32_t n = vio32(p + 28);
    if (!n || n >= lg.rows) return 0x1205;
    lg.first = (lg.first + n) % lg.rows;
    for (uint32_t r = lg.rows - n; r < lg.rows; r++)  /* the rows that came in are blank */
        memset(lg.cells + (size_t)((lg.first + r) % lg.rows) * lg.cols, 0, lg.cols * sizeof *lg.cells);
    overlay_clear_cells(lg.rows - n, n);
    return 0x1100;
}

static uint32_t cursor(const uint8_t *p, size_t len)
{
    if (!lg.cells || len < 24 + 16 || vio32(p + 24)) return 0x1205;
    uint32_t col = vio32(p + 28), row = vio32(p + 32), cells = vio32(p + 36);
    if (cells && (col >= lg.cols || row >= lg.rows || cells > 2)) return 0x1205;
    lg.cur_col = col; lg.cur_row = row; lg.cur_cells = cells;
    return 0x1100;
}

static uint32_t fill(const uint8_t *p, size_t len)
{
    if (!lg.cells || len < 24 + 24 || vio32(p + 24)) return 0x1205;
    uint32_t x = vio32(p + 28), y = vio32(p + 32), w = vio32(p + 36), h = vio32(p + 40), rgb = vio32(p + 44);
    if (!w || !h || x >= lg.width || y >= lg.height || w > lg.width - x || h > lg.height - y) return 0x1205;
    for (uint32_t j = 0; j < h; j++) {
        uint32_t *d = overlay_row(y + j) + x;
        for (uint32_t i = 0; i < w; i++) d[i] = 0xff000000 | (rgb & 0xffffff);
    }
    lg.overlay_used = true;
    return 0x1100;
}

uint32_t logos_command(uint32_t type, const uint8_t *p, size_t len)
{/* One command (caller holds g.lock); a virtio-gpu response type. */
    switch (type) {
    case LOGOS_CMD_GRID: return grid(p, len);
    case LOGOS_CMD_GLYPH: return glyph(p, len);
    case LOGOS_CMD_ROWS: return rows_cmd(p, len);
    case LOGOS_CMD_SCROLL: return scroll(p, len);
    case LOGOS_CMD_CURSOR: return cursor(p, len);
    case LOGOS_CMD_FILL: return fill(p, len);
    case LOGOS_CMD_PRESENT:
        if (!lg.cells || len < 24 + 4 || vio32(p + 24)) return 0x1205;
        changed();
        return 0x1100;
    }
    return 0x1200;
}

/* ---- rendering ---------------------------------------------------------- */

struct uniforms {
    uint32_t width, height, cols, rows, cw, ch, first, per_row, slot_w;
    uint32_t cur_col, cur_row, cur_cells, overlay;
    float scale_x, scale_y;
};

static NSString *const shader_source = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Cell { uint slot, fg, bg, flags; };\n"
    "struct U { uint width, height, cols, rows, cw, ch, first, per_row, slot_w;\n"
    "           uint cur_col, cur_row, cur_cells, overlay; float scale_x, scale_y; };\n"
    "struct V { float4 pos [[position]]; };\n"
    "vertex V vs(uint id [[vertex_id]]) {\n"
    "    float2 p = float2((id << 1) & 2, id & 2);\n"
    "    V v; v.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return v;\n"
    "}\n"
    "float3 rgb(uint c) { return float3((c >> 16) & 255, (c >> 8) & 255, c & 255) / 255.0; }\n"
    "fragment float4 fs(V in [[stage_in]], constant U &u [[buffer(0)]],\n"
    "                   const device Cell *cells [[buffer(1)]],\n"
    "                   texture2d<float, access::read> atlas [[texture(0)]],\n"
    "                   texture2d<float, access::read> overlay [[texture(1)]]) {\n"
    "    uint x = uint(in.pos.x * u.scale_x), y = uint(in.pos.y * u.scale_y);\n"
    "    if (x >= u.width || y >= u.height) return float4(0, 0, 0, 1);\n"
    "    uint grid = u.rows * u.ch, oy = y < grid ? (y + u.first * u.ch) % grid : y;\n"
    "    uint col = x / u.cw, row = y / u.ch;\n"
    "    bool cells_here = x < u.cols * u.cw && y < grid;\n"
    "    float3 color = float3(0);\n"
    "    float4 o = u.overlay ? overlay.read(uint2(x, oy)) : float4(0);\n"
    "    if (o.a > 0.0) color = o.rgb;  /* a filled rectangle over the cells */\n"
    "    else if (cells_here) {\n"
    "        Cell c = cells[((row + u.first) % u.rows) * u.cols + col];\n"
    "        float3 fg = rgb(c.fg), bg = rgb(c.bg);\n"
    "        if (c.flags & 2u) { float3 t = fg; fg = bg; bg = t; }\n"
    "        uint gx = x % u.cw + ((c.flags & 8u) ? u.cw : 0u), gy = y % u.ch;\n"
    "        uint2 a = uint2(c.slot % u.per_row * u.slot_w, c.slot / u.per_row * u.ch);\n"
    "        float cov = atlas.read(a + uint2(gx, gy)).r;\n"
    "        if ((c.flags & 1u) && gx > 0u) cov = max(cov, atlas.read(a + uint2(gx - 1u, gy)).r);\n"
    "        if ((c.flags & 4u) && gy == u.ch - 1u) cov = 1.0;\n"
    "        color = mix(bg, fg, cov);\n"
    "    }\n"
    "    if (cells_here && u.cur_cells && row == u.cur_row && col >= u.cur_col && col < u.cur_col + u.cur_cells)\n"
    "        color = 1.0 - color;  /* the block cursor inverts what is under it */\n"
    "    return float4(color, 1);\n"
    "}\n";

static bool metal_init(void)
{
    if (pipeline) return true;
    device = MTLCreateSystemDefaultDevice();
    if (!device) { LOGE("logos: no Metal device\n"); return false; }
    NSError *err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:shader_source options:nil error:&err];
    if (!lib) { LOGE("logos: shader: %s\n", err.localizedDescription.UTF8String); return false; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"fs"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipeline = [device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!pipeline) { LOGE("logos: pipeline: %s\n", err.localizedDescription.UTF8String); return false; }
    queue = [device newCommandQueue];
    MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                  width:ATLAS_W height:ATLAS_H mipmapped:NO];
    t.usage = MTLTextureUsageShaderRead;
    atlas_tex = [device newTextureWithDescriptor:t];
    return atlas_tex != nil;
}

/* Copy the state for one frame under g.lock, then render the target (width x height guest
 * pixels) into `out`, a BGRA8 texture of any size (scaled, nearest). */
static bool render(id<MTLTexture> out)
{
    struct uniforms u;
    id<MTLBuffer> cells;
    bool overlay;
    pthread_mutex_lock(&g.lock);
    if (!lg.active || !metal_init()) { pthread_mutex_unlock(&g.lock); return false; }
    u = (struct uniforms){lg.width, lg.height, lg.cols, lg.rows, lg.cw, lg.ch, lg.first, lg.per_row, lg.slot_w,
                          lg.cur_col, lg.cur_row, lg.cur_cells, lg.overlay_used,
                          (float)lg.width / out.width, (float)lg.height / out.height};
    cells = [device newBufferWithBytes:lg.cells length:(size_t)lg.cols * lg.rows * sizeof(struct lcell)
                               options:MTLResourceStorageModeShared];
    if (lg.atlas_dirty0 < lg.atlas_dirty1) {
        uint32_t y0 = lg.atlas_dirty0 * lg.ch, h = (lg.atlas_dirty1 - lg.atlas_dirty0) * lg.ch;
        [atlas_tex replaceRegion:MTLRegionMake2D(0, y0, ATLAS_W, h) mipmapLevel:0
                       withBytes:lg.atlas + (size_t)y0 * ATLAS_W bytesPerRow:ATLAS_W];
        lg.atlas_dirty0 = lg.atlas_dirty1 = 0;
    }
    overlay = lg.overlay_used;
    if (overlay) {
        if (overlay_tex_w != lg.width || overlay_tex_h != lg.height) {
            MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:lg.width height:lg.height mipmapped:NO];
            t.usage = MTLTextureUsageShaderRead;
            overlay_tex = [device newTextureWithDescriptor:t];
            overlay_tex_w = lg.width; overlay_tex_h = lg.height;
        }
        [overlay_tex replaceRegion:MTLRegionMake2D(0, 0, lg.width, lg.height) mipmapLevel:0
                         withBytes:lg.overlay bytesPerRow:lg.width * 4];
    }
    pthread_mutex_unlock(&g.lock);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = out;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:pipeline];
    [enc setFragmentBytes:&u length:sizeof u atIndex:0];
    [enc setFragmentBuffer:cells offset:0 atIndex:1];
    [enc setFragmentTexture:atlas_tex atIndex:0];
    [enc setFragmentTexture:overlay ? overlay_tex : atlas_tex atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}

bool logos_snapshot(uint8_t **pixels, uint32_t *width, uint32_t *height)
{/* The target as 0xXXRRGGBB pixels (malloc'd), rendered offscreen: screenshots, headless. */
    @autoreleasepool {
        uint32_t w, h;
        pthread_mutex_lock(&g.lock);
        w = lg.width; h = lg.height;
        bool on = lg.active && metal_init();
        pthread_mutex_unlock(&g.lock);
        if (!on) return false;
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:w height:h mipmapped:NO];
        t.usage = MTLTextureUsageRenderTarget;
        t.storageMode = MTLStorageModeShared;
        id<MTLTexture> out = [device newTextureWithDescriptor:t];
        uint8_t *dst = malloc((size_t)w * h * 4);
        if (!out || !dst || !render(out)) { free(dst); return false; }
        [out getBytes:dst bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        *pixels = dst; *width = w; *height = h;
        return true;
    }
}
