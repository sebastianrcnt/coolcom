/* Rendered Vulkan image -> CAMetalLayer. No guest pixels are read back for a
 * window frame. Screenshots explicitly request one GPU -> shared-buffer copy.
 * Called under g.lock; the display blit completes before a scanout can be reused.
 */
#ifdef COOLVM_VENUS
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include "coolvm.h"
#include "venus-metal.h"
static CAMetalLayer *display_layer;
static id<MTLCommandQueue> queue;
static id<MTLDevice> queue_device;
static id<MTLCommandQueue> texture_queue(id<MTLTexture> texture)
{
    if (queue_device != texture.device) {
        [queue release]; queue_device = texture.device; queue = [queue_device newCommandQueue];
    }
    return queue;
}
void *venus_metal_retain(void *texture) { return [(id)texture retain]; }
void venus_metal_release(void *texture) { [(id)texture release]; }
bool venus_metal_size(void *ptr, uint32_t width, uint32_t height)
{
    id<MTLTexture> texture = (id)ptr;
    return texture && texture.width == width && texture.height == height && texture.pixelFormat == MTLPixelFormatBGRA8Unorm;
}
bool venus_metal_snapshot(void *ptr, uint8_t **pixels, uint32_t width, uint32_t height)
{
    @autoreleasepool {
        id<MTLTexture> texture = (id)ptr;
        if (!venus_metal_size(ptr, width, height)) return false;
        size_t stride = ((size_t)width * 4 + 255) & ~255UL, size = stride * height;
        id<MTLBuffer> buffer = [texture.device newBufferWithLength:size options:MTLResourceStorageModeShared];
        if (!buffer) return false;
        id<MTLCommandBuffer> cmd = [texture_queue(texture) commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(width,height,1) toBuffer:buffer destinationOffset:0
            destinationBytesPerRow:stride destinationBytesPerImage:size];
        [blit endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
        uint8_t *dst = cmd.status == MTLCommandBufferStatusCompleted ? malloc((size_t)width*height*4) : NULL;
        if (dst) for (uint32_t y=0;y<height;y++) memcpy(dst+(size_t)y*width*4,(uint8_t *)buffer.contents+y*stride,width*4);
        [buffer release]; if (!dst) return false; *pixels=dst; return true;
    }
}
bool venus_metal_present(void *ptr, void *parent, uint32_t width, uint32_t height)
{
    @autoreleasepool {
        id<MTLTexture> texture = (id)ptr; CALayer *layer = (id)parent;
        if (!texture || !layer || !venus_metal_size(ptr,width,height)) return false;
        if (!display_layer) {
            display_layer = [[CAMetalLayer alloc] init];
            display_layer.framebufferOnly = NO; display_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            display_layer.displaySyncEnabled = YES; display_layer.maximumDrawableCount = 2;
            [layer addSublayer:display_layer];
        }
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        display_layer.device = texture.device; display_layer.frame = layer.bounds;
        display_layer.drawableSize = CGSizeMake(width,height); display_layer.hidden = NO;
        [CATransaction commit];
        id<CAMetalDrawable> drawable = [display_layer nextDrawable];
        if (!drawable) return false;
        id<MTLCommandBuffer> cmd = [texture_queue(texture) commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(width,height,1) toTexture:drawable.texture destinationSlice:0
            destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [blit endEncoding]; [cmd presentDrawable:drawable]; [cmd commit]; [cmd waitUntilCompleted];
        static bool reported;
        if (!reported && cmd.status == MTLCommandBufferStatusCompleted && getenv("VENUS_PRESENT_DEBUG")) {
            fprintf(stderr,"Venus CAMetalLayer: GPU blit/present completed (no readback)\n"); reported=true;
        }
        return cmd.status == MTLCommandBufferStatusCompleted;
    }
}
void venus_metal_hide(void) { display_layer.hidden = YES; }
#endif
