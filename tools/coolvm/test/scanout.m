/* Compare the actual window's two-slice drawing with an independent flattened
 * scanout, and check exported snapshots at every ring boundary. No VM needed. */
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include "../src/coolvm.h"

struct vm g;
void input_push(uint32_t type, uint32_t code, int32_t value) {}
void vm_stop(int code, const char *why) {}

static CGImageRef image_of(const uint8_t *pixels, CGColorSpaceRef color)
{
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, g.fb_size, NULL);
    CGImageRef image = CGImageCreate(g.fb_width, g.fb_height, 8, 32, g.fb_width * 4,
        color, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        g.fb_width = 64; g.fb_height = 48;
        g.fb_size = g.fb_width * g.fb_height * 4;
        g.fb = malloc(g.fb_size);
        uint8_t *expected = malloc(g.fb_size), *snapshot = malloc(g.fb_size);
        uint8_t *actual = calloc(1, g.fb_size), *reference = calloc(1, g.fb_size);
        for (uint32_t y = 0; y < g.fb_height; ++y)
            for (uint32_t x = 0; x < g.fb_width; ++x)
                ((uint32_t *)g.fb)[y * g.fb_width + x] =
                    ((y * 5) << 16) | ((x * 3) << 8) | ((x + y * 7) & 255);
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGBitmapInfo info = kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little;
        CGContextRef ac = CGBitmapContextCreate(actual, g.fb_width, g.fb_height, 8, g.fb_width * 4, color, info);
        CGContextRef rc = CGBitmapContextCreate(reference, g.fb_width, g.fb_height, 8, g.fb_width * 4, color, info);
        CGRect bounds = CGRectMake(0, 0, g.fb_width, g.fb_height);
        NSView *view = [[NSClassFromString(@"VMView") alloc] initWithFrame:NSRectFromCGRect(bounds)];
        if (!ac || !rc || !view) return 1;
        const double scales[] = {1, 1.5, 0.75};
        for (unsigned scale = 0; scale < sizeof(scales) / sizeof(scales[0]); ++scale) {
            bounds = CGRectMake(0, 0, g.fb_width * scales[scale], g.fb_height * scales[scale]);
            [view setFrame:NSRectFromCGRect(bounds)];
            for (uint32_t top = 0; top < g.fb_height; ++top) {
                atomic_store(&g.fb_scanout_y, top);
                for (uint32_t y = 0; y < g.fb_height; ++y)
                    memcpy(expected + y * g.fb_width * 4,
                           g.fb + ((y + top) % g.fb_height) * g.fb_width * 4, g.fb_width * 4);
                fb_snapshot(snapshot);
                if (memcmp(snapshot, expected, g.fb_size)) {
                    fprintf(stderr, "scanout snapshot differs at offset %u\n", top); return 1;
                }
                memset(actual, 0, g.fb_size); memset(reference, 0, g.fb_size);
                CGImageRef image = image_of(expected, color);
                CGContextDrawImage(rc, bounds, image);
                CGImageRelease(image);
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:ac flipped:NO]];
                [view drawRect:view.bounds];
                [NSGraphicsContext restoreGraphicsState];
                /* CoreGraphics' skipped alpha byte is not a color component. */
                for (size_t i = 0; i < g.fb_size; i += 4)
                    if (memcmp(actual + i, reference + i, 3)) {
                        fprintf(stderr, "window scanout differs at offset %u pixel %zu\n", top, i / 4); return 1;
                    }
                if (argc > 1) {
                    if (!display_screenshot(argv[1])) return 1;
                    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], strlen(argv[1]), false);
                    CGImageSourceRef source = CGImageSourceCreateWithURL(url, NULL);
                    image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
                    if (!image) return 1;
                    CGRect native = CGRectMake(0, 0, g.fb_width, g.fb_height);
                    memset(actual, 0, g.fb_size); memset(reference, 0, g.fb_size);
                    CGContextDrawImage(ac, native, image);
                    CGImageRef expected_image = image_of(expected, color);
                    CGContextDrawImage(rc, native, expected_image);
                    CGImageRelease(expected_image);
                    for (size_t i = 0; i < g.fb_size; i += 4)
                        if (memcmp(actual + i, reference + i, 3)) {
                            fprintf(stderr, "PNG scanout differs at offset %u pixel %zu\n", top, i / 4); return 1;
                        }
                    CGImageRelease(image); CFRelease(source); CFRelease(url);
                }
            }
        }
        CGContextRelease(ac); CGContextRelease(rc); CGColorSpaceRelease(color);
        [view release];
        free(reference); free(actual); free(snapshot); free(expected); free(g.fb);
        puts("scanout: all offsets and scales match window, snapshot and PNG pixels");
    }
    return 0;
}
