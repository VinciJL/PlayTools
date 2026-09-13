#import "RenderServerCapture.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

// The render server compositor was validated with an on-device spike:
// - CARenderServerRenderLayer is a client-side wrapper that dereferences the
//   layer argument as a CALayer object -> the object pointer must be passed
//   (passing CALayerGetRenderId's value crashes with far = renderId + 16).
// - The context id comes from CALayerGetContext(layer).contextId.
// - Capturing one's own window needs no privacy permission (only whole
//   display capture does).
// - Output rows are top-first BGRA, no flip required.

typedef struct __Surface *PTSurfaceRef;
typedef void (*PTSetDrawableFn)(uint32_t, uint32_t, uint64_t, PTSurfaceRef, int32_t, int32_t);
typedef id (*PTGetContextFn)(id);

static PTSetDrawableFn PTRenderServerRenderLayer;
static PTGetContextFn PTGetLayerContext;
static BOOL PTSymbolsReady;

static PTSurfaceRef (*PTSurfaceCreate)(CFDictionaryRef);
static void *(*PTSurfaceBase)(PTSurfaceRef);
static size_t (*PTSurfaceBytesPerRow)(PTSurfaceRef);
static size_t (*PTSurfaceWidth)(PTSurfaceRef);
static size_t (*PTSurfaceHeight)(PTSurfaceRef);
static int (*PTSurfaceLock)(PTSurfaceRef, uint32_t, void *);
static int (*PTSurfaceUnlock)(PTSurfaceRef, uint32_t, void *);

static void PTRenderServerLoadOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        PTRenderServerRenderLayer =
            (PTSetDrawableFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderLayer");
        PTGetLayerContext = (PTGetContextFn)dlsym(RTLD_DEFAULT, "CALayerGetContext");

        void *surface = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface",
                               RTLD_NOW);
        if (surface != NULL) {
            PTSurfaceCreate = dlsym(surface, "IOSurfaceCreate");
            PTSurfaceBase = dlsym(surface, "IOSurfaceGetBaseAddress");
            PTSurfaceBytesPerRow = dlsym(surface, "IOSurfaceGetBytesPerRow");
            PTSurfaceWidth = dlsym(surface, "IOSurfaceGetWidth");
            PTSurfaceHeight = dlsym(surface, "IOSurfaceGetHeight");
            PTSurfaceLock = dlsym(surface, "IOSurfaceLock");
            PTSurfaceUnlock = dlsym(surface, "IOSurfaceUnlock");
        }
        PTSymbolsReady = PTRenderServerRenderLayer != NULL && PTGetLayerContext != NULL &&
            PTSurfaceCreate != NULL && PTSurfaceBase != NULL && PTSurfaceBytesPerRow != NULL &&
            PTSurfaceLock != NULL && PTSurfaceUnlock != NULL;
    });
}

BOOL PTRenderServerCaptureAvailable(void) {
    PTRenderServerLoadOnce();
    return PTSymbolsReady;
}

static UIWindow *PTKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) { continue; }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) { return window; }
        }
    }
    return nil;
}

static uint32_t PTContextIdForLayer(CALayer *layer) {
    id context = PTGetLayerContext(layer);
    SEL selector = NSSelectorFromString(@"contextId");
    if (context == nil || ![context respondsToSelector:selector]) { return 0; }
    return ((uint32_t (*)(id, SEL))objc_msgSend)(context, selector);
}

NSData *PTRenderServerCaptureKeyWindow(NSUInteger width, NSUInteger height) {
    PTRenderServerLoadOnce();
    if (!PTSymbolsReady || width < 1 || height < 1) { return nil; }

    UIWindow *window = PTKeyWindow();
    CALayer *layer = window.layer;
    if (layer == nil) { return nil; }

    uint32_t contextId = PTContextIdForLayer(layer);
    if (contextId == 0) { return nil; }

    NSDictionary *properties = @{
        @"IOSurfaceWidth": @(width),
        @"IOSurfaceHeight": @(height),
        @"IOSurfaceBytesPerElement": @4,
        @"IOSurfacePixelFormat": @(0x42475241),  // 'BGRA'
    };
    PTSurfaceRef surface = PTSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (surface == NULL) { return nil; }

    // The layer argument is the CALayer object pointer (see the note above)
    uint64_t layerPointer = (uint64_t)(uintptr_t)(__bridge void *)layer;
    PTRenderServerRenderLayer(0, contextId, layerPointer, surface, 0, 0);

    NSData *data = nil;
    if (PTSurfaceLock(surface, 0x1, NULL) == 0) {  // kIOSurfaceLockReadOnly
        size_t surfaceWidth = PTSurfaceWidth(surface);
        size_t surfaceHeight = PTSurfaceHeight(surface);
        size_t sourceRowBytes = PTSurfaceBytesPerRow(surface);
        size_t rowBytes = surfaceWidth * 4;
        const uint8_t *base = PTSurfaceBase(surface);
        if (base != NULL && rowBytes > 0) {
            NSMutableData *buffer = [NSMutableData dataWithLength:rowBytes * surfaceHeight];
            uint8_t *destination = buffer.mutableBytes;
            for (size_t row = 0; row < surfaceHeight; row++) {
                memcpy(destination + row * rowBytes, base + row * sourceRowBytes, rowBytes);
            }
            data = buffer;
        }
        PTSurfaceUnlock(surface, 0x1, NULL);
    }
    CFRelease(surface);
    return data;
}
