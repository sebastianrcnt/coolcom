#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>
#include "coolvm.h"

static CGImageRef framebuffer_image(void)
{
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, g.fb, g.fb_width*g.fb_height*4, NULL);
    CGImageRef image = CGImageCreate(g.fb_width, g.fb_height, 8, 32, g.fb_width*4,
        color, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(color);
    return image;
}

bool display_screenshot(const char *path)
{
    CGImageRef image = framebuffer_image();
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
    [20]=4,[21]=5,[22]=6,[23]=7,[24]=8,[25]=9,[26]=10,[27]=11,[28]=12,
    [29]=13,[30]=27,[31]=24,[32]=22,[33]=26,[34]=23,[35]=25,[36]=28,
    [37]=38,[38]=36,[39]=40,[40]=37,[41]=39,[42]=43,[43]=51,[44]=53,
    [45]=49,[46]=50,[47]=52,[48]=15,[49]=57,[51]=14,[53]=1,
    [54]=126,[55]=125,[56]=42,[57]=58,[58]=56,[59]=29,[60]=54,[61]=100,[62]=97,
    [123]=105,[124]=106,[125]=108,[126]=103
};

@interface VMView : NSView
@end
@implementation VMView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGImageRef image = framebuffer_image();
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGContextDrawImage(ctx, self.bounds, image);
    CGImageRelease(image);
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
- (void)mouseDown:(NSEvent *)event { (void)event; input_push(1,272,1); input_push(0,0,0); }
- (void)mouseUp:(NSEvent *)event { (void)event; input_push(1,272,0); input_push(0,0,0); }
- (void)rightMouseDown:(NSEvent *)event { (void)event; input_push(1,273,1); input_push(0,0,0); }
- (void)rightMouseUp:(NSEvent *)event { (void)event; input_push(1,273,0); input_push(0,0,0); }
- (void)mouseMoved:(NSEvent *)event { if ((int)event.deltaX) input_push(2,0,(int)event.deltaX); if ((int)event.deltaY) input_push(2,1,(int)-event.deltaY); input_push(0,0,0); }
- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)scrollWheel:(NSEvent *)event { input_push(2,8,(int)event.scrollingDeltaY); input_push(0,0,0); }
@end

@interface VMWindowDelegate : NSObject <NSWindowDelegate>
@end
@implementation VMWindowDelegate
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
}
void display_pump(void)
{
    if (g.headless) return;
    @autoreleasepool {
        NSEvent *ev;
        while ((ev = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES]))
            [NSApp sendEvent:ev];
        [view setNeedsDisplay:YES];
        [view displayIfNeeded];
    }
}
