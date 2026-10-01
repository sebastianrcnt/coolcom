#include "scroll.h"
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>
#import <QuartzCore/QuartzCore.h>
#include "coolvm.h"
#include "gpu3d.h"
#include "venus-metal.h"
#include <math.h>

void fb_snapshot(uint8_t *dst)
{
    size_t stride = (size_t)g.fb_width * 4;
    uint32_t top = atomic_load(&g.fb_scanout_y);
    size_t first = (g.fb_height - top) * stride;
    memcpy(dst, g.fb + top * stride, first);
    memcpy(dst + first, g.fb, top * stride);
}

/* The window draws the two physical slices directly. Only exported screenshots
 * and raw frame dumps flatten the ring into a contiguous visible image. */
static CGImageRef framebuffer_slice(uint32_t y, uint32_t height)
{
    size_t stride = (size_t)g.fb_width * 4;
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, g.fb + y * stride,
                                                            height * stride, NULL);
    CGImageRef image = CGImageCreate(g.fb_width, height, 8, 32, stride,
        color, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(color);
    return image;
}

static void release_pixels(void *info, const void *data, size_t size)
{
    (void)info; (void)size;
    free((void *)data);
}

static CGImageRef framebuffer_image(bool cursor)
{
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    uint8_t *visible = NULL;
    uint32_t width = g.fb_width, height = g.fb_height;
    bool gpu_image = false;
    if (g.gpu && !gpu_image) {
        pthread_mutex_lock(&g.lock);
        gpu_image = gpu_snapshot(&visible, &width, &height, cursor);
        pthread_mutex_unlock(&g.lock);
    }
    size_t size = (size_t)width * height * 4;
    CGDataProviderRef provider;
    if (gpu_image)
        provider = CGDataProviderCreateWithData(NULL, visible, size, release_pixels);
    else
    if (atomic_load(&g.fb_scanout_y)) {
        uint8_t *pixels = malloc(size);
        if (!pixels) { CGColorSpaceRelease(color); return NULL; }
        fb_snapshot(pixels);
        provider = CGDataProviderCreateWithData(NULL, pixels, size, release_pixels);
    } else
        provider = CGDataProviderCreateWithData(NULL, g.fb, size, NULL);
    CGImageRef image = CGImageCreate(width, height, 8, 32, width*4,
        color, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(color);
    return image;
}

bool display_screenshot(const char *path)
{
    CGImageRef image = framebuffer_image(true);
    if (!image) return false;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    bool ok = dst && (CGImageDestinationAddImage(dst, image, NULL), CGImageDestinationFinalize(dst));
    if (dst) CFRelease(dst);
    CFRelease(url);
    CGImageRelease(image);
    return ok;
}

static const uint16_t keymap[128] = {
    [0]=30,[1]=31,[2]=32,[3]=33,[4]=35,[5]=34,[6]=44,[7]=45,[8]=46,[9]=47,
    [11]=48,[12]=16,[13]=17,[14]=18,[15]=19,[16]=21,[17]=20,[18]=2,[19]=3,
    /* the number row is not in order: kVK_ANSI_6=22, 5=23, Equal=24, 9=25, 7=26, Minus=27, 8=28, 0=29 */
    [20]=4,[21]=5,[22]=7,[23]=6,[24]=13,[25]=10,[26]=8,[27]=12,[28]=9,
    [29]=11,[30]=27,[31]=24,[32]=22,[33]=26,[34]=23,[35]=25,[36]=28,
    [37]=38,[38]=36,[39]=40,[40]=37,[41]=39,[42]=43,[43]=51,[44]=53,
    [45]=49,[46]=50,[47]=52,[48]=15,[49]=57,[50]=41,[51]=14,[53]=1,
    [54]=126,[55]=125,[56]=42,[57]=58,[58]=56,[59]=29,[60]=54,[61]=100,[62]=97,
    [115]=102,[117]=111,[119]=107, /* Home, Forward Delete, End */
    [116]=104,[121]=109,[114]=110, /* Page Up, Page Down, Help/Insert */
    /* F1..F12 */
    [122]=59,[120]=60,[99]=61,[118]=62,[96]=63,[97]=64,[98]=65,[100]=66,[101]=67,[109]=68,[103]=87,[111]=88,
    [123]=105,[124]=106,[125]=108,[126]=103
};

@interface VMView : NSView {
    struct scroll_accumulator scroll;
    NSCursor *guestCursor;
    uint64_t cursorSerial;
    CGFloat cursorScaleX, cursorScaleY;
}
- (void)updateGuestCursor;
@end
@implementation VMView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:guestCursor ?: NSCursor.arrowCursor]; }
- (void)updateGuestCursor {
    if (!g.gpu) return;
    uint32_t pixels[64*64],hx,hy;bool visible;
    uint32_t w=g.fb_width,h=g.fb_height;
    pthread_mutex_lock(&g.lock);
    uint64_t serial=gpu_cursor_snapshot(pixels,&hx,&hy,&visible);
    /* The current guest scanout may resize without changing the original FDT. */
    w=gpu_display_width();h=gpu_display_height();
    pthread_mutex_unlock(&g.lock);
    CGFloat sx=self.bounds.size.width/w,sy=self.bounds.size.height/h;
    if (serial==cursorSerial && sx==cursorScaleX && sy==cursorScaleY) return;
    cursorSerial=serial;cursorScaleX=sx;cursorScaleY=sy;
    NSCursor *next=nil;
    if (visible) {
        NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
            pixelsWide:64 pixelsHigh:64 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
            isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:256 bitsPerPixel:32];
        uint8_t *dst=rep.bitmapData;
        for (unsigned i=0;i<64*64;i++) {
            dst[4*i]=(pixels[i]>>16)&255;dst[4*i+1]=(pixels[i]>>8)&255;
            dst[4*i+2]=pixels[i]&255;dst[4*i+3]=pixels[i]>>24;
        }
        NSImage *image=[[NSImage alloc] initWithSize:NSMakeSize(64*sx,64*sy)];
        [image addRepresentation:rep];
        next=[[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(hx*sx,hy*sy)];
        [image release];[rep release];
    }
    [guestCursor release];guestCursor=next;
    [self.window invalidateCursorRectsForView:self];
    if (NSPointInRect([self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil],self.bounds))
        [(guestCursor ?: NSCursor.arrowCursor) set];
    if (getenv("COOLVM_CURSOR_DEBUG")) fprintf(stderr,"NATIVE CURSOR %s %llu %.3f %.3f %u %u\n",visible?"shape":"default",(unsigned long long)serial,(double)sx,(double)sy,hx,hy);
}
- (void)dealloc { [guestCursor release];[super dealloc]; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (g.gpu) {
#ifdef COOLVM_VENUS
        self.wantsLayer = YES;
        pthread_mutex_lock(&g.lock);
        uint32_t w,h; void *texture = gpu3d_display_texture(&w,&h);
        bool direct = texture && venus_metal_present(texture,self.layer,w,h);
        pthread_mutex_unlock(&g.lock);
        if (direct) return;
        venus_metal_hide();
#endif
        CGImageRef image = framebuffer_image(false);
        CGContextDrawImage(ctx, NSRectToCGRect(self.bounds), image);
        CGImageRelease(image);
        return;
    }
    uint32_t top = atomic_load(&g.fb_scanout_y), first = g.fb_height - top;
    CGRect bounds = NSRectToCGRect(self.bounds);
    CGSize device = CGContextConvertSizeToDeviceSpace(ctx, bounds.size);
    if (fabs(device.width) != g.fb_width || fabs(device.height) != g.fb_height) {
        /* Interpolation across the ring seam needs neighboring visible rows.
         * Flatten scaled displays to retain the old whole-image filtering. */
        CGImageRef image = framebuffer_image(false);
        CGContextDrawImage(ctx, bounds, image);
        CGImageRelease(image);
        return;
    }
    CGFloat scale = bounds.size.height / g.fb_height;
    CGImageRef image = framebuffer_slice(top, first);
    CGContextDrawImage(ctx, CGRectMake(bounds.origin.x, bounds.origin.y + top * scale,
                                      bounds.size.width, first * scale), image);
    CGImageRelease(image);
    if (top) {
        image = framebuffer_slice(0, top);
        CGContextDrawImage(ctx, CGRectMake(bounds.origin.x, bounds.origin.y,
                                          bounds.size.width, top * scale), image);
        CGImageRelease(image);
    }
}
- (void)keyDown:(NSEvent *)event {
    /* macOS virtual key codes to Linux KEY_* for common keyboard keys. */
    unsigned code = event.keyCode < 128 ? keymap[event.keyCode] : 0;
    if (code) { input_push(1, code, event.isARepeat ? 2 : 1); input_push(0, 0, 0); }
}
- (void)keyUp:(NSEvent *)event {
    unsigned code = event.keyCode < 128 ? keymap[event.keyCode] : 0;
    if (code) { input_push(1, code, 0); input_push(0, 0, 0); }
}
- (void)flagsChanged:(NSEvent *)event {
    NSEventModifierFlags bit = 0;
    switch (event.keyCode) {
    case 54: case 55: bit = NSEventModifierFlagCommand; break;
    case 56: case 60: bit = NSEventModifierFlagShift; break;
    case 58: case 61: bit = NSEventModifierFlagOption; break;
    case 59: case 62: bit = NSEventModifierFlagControl; break;
    case 57: bit = NSEventModifierFlagCapsLock; break;
    default: return;
    }
    unsigned code = keymap[event.keyCode];
    input_push(1, code, (event.modifierFlags & bit) ? 1 : 0);
    input_push(0, 0, 0);
}
- (void)mouseDown:(NSEvent *)event { [self mouseMoved:event]; input_push(1,272,1); input_push(0,0,0); }
- (void)mouseUp:(NSEvent *)event { (void)event; input_push(1,272,0); input_push(0,0,0); }
- (void)rightMouseDown:(NSEvent *)event { [self mouseMoved:event]; input_push(1,273,1); input_push(0,0,0); }
- (void)rightMouseUp:(NSEvent *)event { (void)event; input_push(1,273,0); input_push(0,0,0); }
/* The pointer goes as an absolute position (EV_ABS, 0..32767 across the view, y from the
 * top), so the guest's cursor sits under the Mac's and Retina, window size and
 * acceleration don't matter. Relative deltas drifted, and AppKit's y points up. */
- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect b = self.bounds;
    if (b.size.width < 1 || b.size.height < 1) return;
    double x = (p.x - b.origin.x) / b.size.width, y = 1.0 - (p.y - b.origin.y) / b.size.height;
    x = x < 0 ? 0 : x > 1 ? 1 : x; y = y < 0 ? 0 : y > 1 ? 1 : y;
    input_push(3, 0, (int)(x * 32767)); input_push(3, 1, (int)(y * 32767)); input_push(0, 0, 0);
}
- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)scrollWheel:(NSEvent *)event {
    int x, y;
    scroll_lines(&scroll, event.scrollingDeltaX, event.scrollingDeltaY,
                 event.hasPreciseScrollingDeltas, self.window.backingScaleFactor,
                 (event.phase & NSEventPhaseCancelled) || (event.momentumPhase & NSEventPhaseCancelled),
                 event.momentumPhase != NSEventPhaseNone && !(event.momentumPhase & NSEventPhaseEnded), &x, &y);
    if (x) input_push(2,6,x); // Linux REL_HWHEEL, signed lines.
    if (y) input_push(2,8,y); // Linux REL_WHEEL, signed lines.
    if (x || y) input_push(0,0,0);
}
@end

@interface VMWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation VMWindowDelegate
- (void)windowDidResize:(NSNotification *)notification {
    NSWindow *window = notification.object;
    NSRect pixels = [window.contentView convertRectToBacking:window.contentView.bounds];
    gpu_scale(window.backingScaleFactor >= 1.5 ? 2 : 1);
    gpu_resize((uint32_t)llround(pixels.size.width), (uint32_t)llround(pixels.size.height));
}
- (void)windowDidChangeBackingProperties:(NSNotification *)notification { [self windowDidResize:notification]; }
- (void)windowWillClose:(NSNotification *)notification { (void)notification; vm_stop(0, "window closed"); }
@end

static VMView *view;
static VMWindowDelegate *windowDelegate;
void display_init(void)
{
    if (g.headless) return;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSRect rect = NSMakeRect(0, 0, g.fb_width, g.fb_height);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:rect styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    windowDelegate = [[VMWindowDelegate alloc] init];
    [window setDelegate:windowDelegate];
    [window setTitle:@"coolvm"];
    view = [[VMView alloc] initWithFrame:rect];
    [window setContentView:view];
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:view];
    [window setAcceptsMouseMovedEvents:YES];
    [NSApp activateIgnoringOtherApps:YES];
    [windowDelegate windowDidResize:[NSNotification notificationWithName:NSWindowDidResizeNotification object:window]];
}
/* Run the event loop for `seconds`: events are handled as they arrive, and once per
 * screen frame the window is redrawn and committed if the guest changed the framebuffer.
 * A guest that reports the rows it drew (FINISHER_FB_DAMAGE, coolvm.h) says so; for any
 * other the guest writes RAM directly, so a copy of the last frame shown is the only way
 * to tell. The old loop handled events and redrew every 50 ms, and the drawing reached the
 * screen one more pump later: 0.1-0.15 s from key to echo. */
void display_pump(double seconds)
{
    static uint8_t *shown;
    static double frame, next, fast_until;
    if (g.headless) return;
    if (!shown) {
        shown = calloc(1, g.fb_size);
        NSInteger fps = [NSScreen mainScreen].maximumFramesPerSecond;
        frame = 1.0 / (fps >= 60 ? fps : 60);
    }
    double now = CFAbsoluteTimeGetCurrent(), end = now + seconds;
    while (now < end && !atomic_load(&g.stop)) {
        @autoreleasepool {
            if (next < now) next = now;
            NSEvent *ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                untilDate:[NSDate dateWithTimeIntervalSinceReferenceDate:next < end ? next : end]
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (ev) {
                [NSApp sendEvent:ev];
                if (ev.type == NSEventTypeKeyDown || ev.type == NSEventTypeLeftMouseDown) {
                    /* The guest answers in 1-3 ms: look every millisecond for a while. */
                    now = CFAbsoluteTimeGetCurrent();
                    fast_until = now + 0.02;
                    if (next > now + 0.001) next = now + 0.001;
                }
            }
            now = CFAbsoluteTimeGetCurrent();
            if (now >= next) {
                next = now + (now < fast_until ? 0.001 : frame);
                [view updateGuestCursor];
                bool changed;
                if (atomic_load(&g.fb_damage_used))
                    changed = atomic_exchange(&g.fb_damage, 0) != 0;
                else if ((changed = memcmp(shown, g.fb, g.fb_size) != 0))
                    memcpy(shown, g.fb, g.fb_size);
                if (changed) {
                    fast_until = 0;
                    [view setNeedsDisplay:YES];
                    [view displayIfNeeded];
                    [CATransaction flush];
                }
            }
        }
    }
}
