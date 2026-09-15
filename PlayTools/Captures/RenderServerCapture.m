#import "RenderServerCapture.h"

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

// 私有符号始终运行时探测；不可用时由显示管线退回普通窗口路径。
// CARenderServerRenderLayer 系列的 layer 参数必须是实际 CALayer 对象指针，而不是 render id。
typedef struct __Surface *PTIOSurfaceRef;
// 带变换的渲染变体：transform 负责把 layer 的坐标空间映射到 surface 像素空间。
typedef void (*PTSetDrawableWithTransformFn)(uint32_t, uint32_t, uint64_t, PTIOSurfaceRef,
                                             int32_t, int32_t, const CATransform3D *);
typedef id (*PTGetContextFn)(id);

typedef PTIOSurfaceRef (*PTSurfaceCreateFn)(CFDictionaryRef);
typedef void *(*PTSurfaceBaseFn)(PTIOSurfaceRef);
typedef size_t (*PTSurfaceSizeFn)(PTIOSurfaceRef);
typedef int (*PTSurfaceLockFn)(PTIOSurfaceRef, uint32_t, void *);
typedef int (*PTSurfaceUnlockFn)(PTIOSurfaceRef, uint32_t, void *);

static PTSetDrawableWithTransformFn PTRenderServerRenderLayerWithTransform;
static PTGetContextFn PTGetLayerContext;
static PTSurfaceCreateFn PTSurfaceCreate;
static PTSurfaceBaseFn PTSurfaceBase;
static PTSurfaceSizeFn PTSurfaceBytesPerRow;
static PTSurfaceSizeFn PTSurfaceWidth;
static PTSurfaceSizeFn PTSurfaceHeight;
static PTSurfaceLockFn PTSurfaceLock;
static PTSurfaceUnlockFn PTSurfaceUnlock;
static BOOL PTSymbolsReady;

static void PTRenderServerLoadOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        PTRenderServerRenderLayerWithTransform =
            (PTSetDrawableWithTransformFn)dlsym(RTLD_DEFAULT,
                                                "CARenderServerRenderLayerWithTransform");
        PTGetLayerContext = (PTGetContextFn)dlsym(RTLD_DEFAULT, "CALayerGetContext");

        void *surfaceFramework = dlopen(
            "/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
        if (surfaceFramework != NULL) {
            PTSurfaceCreate = (PTSurfaceCreateFn)dlsym(surfaceFramework, "IOSurfaceCreate");
            PTSurfaceBase = (PTSurfaceBaseFn)dlsym(surfaceFramework, "IOSurfaceGetBaseAddress");
            PTSurfaceBytesPerRow =
                (PTSurfaceSizeFn)dlsym(surfaceFramework, "IOSurfaceGetBytesPerRow");
            PTSurfaceWidth = (PTSurfaceSizeFn)dlsym(surfaceFramework, "IOSurfaceGetWidth");
            PTSurfaceHeight = (PTSurfaceSizeFn)dlsym(surfaceFramework, "IOSurfaceGetHeight");
            PTSurfaceLock = (PTSurfaceLockFn)dlsym(surfaceFramework, "IOSurfaceLock");
            PTSurfaceUnlock = (PTSurfaceUnlockFn)dlsym(surfaceFramework, "IOSurfaceUnlock");
        }

        PTSymbolsReady = PTGetLayerContext != NULL &&
            PTSurfaceCreate != NULL && PTSurfaceBase != NULL &&
            PTSurfaceBytesPerRow != NULL && PTSurfaceWidth != NULL &&
            PTSurfaceHeight != NULL && PTSurfaceLock != NULL &&
            PTSurfaceUnlock != NULL;
    });
}

BOOL PTRenderServerScaledCaptureAvailable(void) {
    PTRenderServerLoadOnce();
    return PTSymbolsReady && PTRenderServerRenderLayerWithTransform != NULL;
}

static uint32_t PTContextIdForLayer(CALayer *layer) {
    if (layer == nil || PTGetLayerContext == NULL) {
        return 0;
    }
    id context = PTGetLayerContext(layer);
    SEL selector = NSSelectorFromString(@"contextId");
    if (context == nil || ![context respondsToSelector:selector]) {
        return 0;
    }
    return ((uint32_t (*)(id, SEL))objc_msgSend)(context, selector);
}

static NSDictionary *PTSurfaceProperties(NSUInteger width, NSUInteger height) {
    return @{
        @"IOSurfaceWidth": @(width),
        @"IOSurfaceHeight": @(height),
        @"IOSurfaceBytesPerElement": @4,
        @"IOSurfacePixelFormat": @(0x42475241), // BGRA
    };
}

PTSurfaceRef PTRenderServerCreateSurface(NSUInteger width, NSUInteger height) {
    PTRenderServerLoadOnce();
    if (!PTSymbolsReady || width < 1 || height < 1) {
        return NULL;
    }
    return (PTSurfaceRef)PTSurfaceCreate((__bridge CFDictionaryRef)PTSurfaceProperties(width, height));
}

BOOL PTRenderServerRenderLayerFittedIntoSurface(CALayer *layer, PTSurfaceRef surface) {
    PTRenderServerLoadOnce();
    if (!PTRenderServerScaledCaptureAvailable() || layer == nil || surface == NULL) {
        return NO;
    }

    uint32_t contextId = PTContextIdForLayer(layer);
    if (contextId == 0) {
        return NO;
    }

    CGSize layerSize = layer.bounds.size;
    size_t surfaceWidth = PTSurfaceWidth((PTIOSurfaceRef)surface);
    size_t surfaceHeight = PTSurfaceHeight((PTIOSurfaceRef)surface);
    if (layerSize.width <= 0 || layerSize.height <= 0 ||
        surfaceWidth == 0 || surfaceHeight == 0) {
        return NO;
    }

    // 不带变换的 CARenderServerRenderLayer 按 layer 原生设备尺寸 1:1 渲染，
    // 窗口尺寸和固定画布不一致时只会得到左上角裁切放大的画面。这里按 WebKit
    // 快照同样的做法，用缩放变换把整棵树映射到 surface 像素空间，使合成结果
    // 恰好是固定画布尺寸（宽高各自缩放，和 presenter 的铺满显示保持一致）。
    CATransform3D transform = CATransform3DMakeScale(
        (CGFloat)surfaceWidth / layerSize.width,
        (CGFloat)surfaceHeight / layerSize.height,
        1);
    transform = CATransform3DTranslate(transform,
                                       -layer.bounds.origin.x,
                                       -layer.bounds.origin.y,
                                       0);
    uint64_t layerPointer = (uint64_t)(uintptr_t)(__bridge void *)layer;
    PTRenderServerRenderLayerWithTransform(0, contextId, layerPointer,
                                           (PTIOSurfaceRef)surface, 0, 0, &transform);
    return YES;
}

void PTRenderServerReleaseSurface(PTSurfaceRef surface) {
    if (surface != NULL) {
        CFRelease((CFTypeRef)surface);
    }
}

NSData *PTRenderServerCopySurface(PTSurfaceRef surface,
                                  NSUInteger * _Nullable width,
                                  NSUInteger * _Nullable height) {
    PTRenderServerLoadOnce();
    if (!PTSymbolsReady || surface == NULL) {
        return nil;
    }

    if (PTSurfaceLock((PTIOSurfaceRef)surface, 0x1, NULL) != 0) { // kIOSurfaceLockReadOnly
        return nil;
    }

    size_t surfaceWidth = PTSurfaceWidth((PTIOSurfaceRef)surface);
    size_t surfaceHeight = PTSurfaceHeight((PTIOSurfaceRef)surface);
    size_t sourceRowBytes = PTSurfaceBytesPerRow((PTIOSurfaceRef)surface);
    size_t rowBytes = surfaceWidth * 4;
    const uint8_t *base = PTSurfaceBase((PTIOSurfaceRef)surface);
    NSData *data = nil;

    if (width != NULL) {
        *width = surfaceWidth;
    }
    if (height != NULL) {
        *height = surfaceHeight;
    }

    if (base != NULL && sourceRowBytes >= rowBytes && rowBytes > 0 && surfaceHeight > 0) {
        NSMutableData *buffer = [NSMutableData dataWithLength:rowBytes * surfaceHeight];
        uint8_t *destination = buffer.mutableBytes;
        for (size_t row = 0; row < surfaceHeight; row++) {
            memcpy(destination + row * rowBytes, base + row * sourceRowBytes, rowBytes);
        }
        data = buffer;
    }

    PTSurfaceUnlock((PTIOSurfaceRef)surface, 0x1, NULL);
    return data;
}
