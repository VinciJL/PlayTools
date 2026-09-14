#import "RenderServerCapture.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

// RenderServer 私有符号必须运行时解析；缺失时由上层回退到旧截图路径。
// 第三个参数必须传入 CALayer 对象指针，不能传 render id；contextId 从 CALayerGetContext 获取。
// 捕获当前窗口不需要录屏权限；输出为顶部起始的 BGRA，无需翻转。

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
            PTSurfaceWidth != NULL && PTSurfaceHeight != NULL &&
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
        @"IOSurfacePixelFormat": @(0x42475241),  // BGRA
    };
    PTSurfaceRef surface = PTSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (surface == NULL) { return nil; }

    // 真实窗口已经包含完整合成结果，直接捕获即可，不再修改任何子视图变换。
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
