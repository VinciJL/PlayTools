#import "CanvasDisplayPipeline.h"

#import "Captures/RenderServerCapture.h"
#import "DrawableSizePin.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <os/log.h>
#include <math.h>

// 管线关键状态变化统一走 os_log，便于用 log show 定位启动失败原因。
static os_log_t PTCanvasLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("PlayTools", "CanvasDisplay");
    });
    return log;
}

static NSString * const PTCanvasPresenterName = @"com.playcover.mode7.canvas-presenter";
enum {
    // 当前 surface 加上三个延迟回收的旧 surface，避免每三帧出现空槽位。
    PTCanvasSurfaceSlotCount = 4,
};
static const NSUInteger PTCanvasRetireDelay = 3;
static const NSUInteger PTCanvasFailureLimit = 6;

typedef struct {
    PTSurfaceRef surface;
    NSUInteger retireAfterTick;
} PTCanvasSurfaceSlot;

static BOOL PTLayerIsDescendantOf(CALayer *layer, CALayer *ancestor) {
    for (CALayer *current = layer; current != nil; current = current.superlayer) {
        if (current == ancestor) {
            return YES;
        }
    }
    return NO;
}

static BOOL PTLayerRectIsValid(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height) &&
        rect.size.width > 0.0 && rect.size.height > 0.0;
}

@interface PTCanvasDisplayController : NSObject {
    UIWindow *_sourceWindow;
    NSObject *_hostWindow;
    CALayer *_sourceLayer;
    CALayer *_presenterParentLayer;
    CALayer *_presenterLayer;
    CGRect _sourceWindowRect;
    CGRect _presenterRect;
    BOOL _geometryValid;
    CADisplayLink *_displayLink;
    PTCanvasSurfaceSlot _slots[PTCanvasSurfaceSlotCount];
    NSUInteger _currentSlot;
    NSUInteger _displayTick;
    NSUInteger _canvasWidth;
    NSUInteger _canvasHeight;
    NSUInteger _consecutiveFailures;
    BOOL _active;
}

- (BOOL)startWithSourceWindow:(UIWindow *)sourceWindow
                   hostWindow:(NSObject *)hostWindow
                         width:(NSUInteger)width
                        height:(NSUInteger)height;
- (BOOL)updateBindingWithSourceWindow:(UIWindow *)sourceWindow
                           hostWindow:(NSObject *)hostWindow;
- (void)stop;
- (NSData *)copyCurrentFrameWithWidth:(NSUInteger *)width height:(NSUInteger *)height;
- (BOOL)copyGeometry:(PTCanvasDisplayGeometry *)geometry;
@property(nonatomic, readonly) BOOL active;

@end

@implementation PTCanvasDisplayController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _currentSlot = NSNotFound;
    }
    return self;
}

- (BOOL)active {
    return _active && _geometryValid && _currentSlot != NSNotFound;
}

- (CALayer *)contentLayerForHostWindow:(NSObject *)hostWindow {
    if (hostWindow == nil) {
        return nil;
    }

    id contentView = [hostWindow valueForKey:@"contentView"];
    SEL wantsLayerSelector = NSSelectorFromString(@"setWantsLayer:");
    if ([contentView respondsToSelector:wantsLayerSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(contentView, wantsLayerSelector, YES);
    }

    id layer = [contentView valueForKey:@"layer"];
    if (![layer isKindOfClass:[CALayer class]]) {
        return nil;
    }
    return (CALayer *)layer;
}

- (void)removePresentersFromLayerTree:(CALayer *)rootLayer {
    for (CALayer *layer in [rootLayer.sublayers copy]) {
        if ([layer.name isEqualToString:PTCanvasPresenterName]) {
            [layer removeFromSuperlayer];
            continue;
        }
        [self removePresentersFromLayerTree:layer];
    }
}

- (BOOL)preparePresenterForSourceLayer:(CALayer *)sourceLayer
                            hostWindow:(NSObject *)hostWindow {
    // host content layer 只用于确保宿主视图 layer-backing 与清理旧 presenter。
    // iOS-on-Mac 运行时里 UIWindow 的 layer 不一定挂在 contentView 的 layer 树下，
    // 因此不再把它当作 presenter 的挂载前提；presenter 只需要与 source layer 同级。
    CALayer *hostLayer = [self contentLayerForHostWindow:hostWindow];
    CALayer *sourceParent = sourceLayer.superlayer;
    if (sourceLayer == nil || sourceParent == nil ||
        sourceParent == sourceLayer || PTLayerIsDescendantOf(sourceParent, sourceLayer)) {
        os_log_error(PTCanvasLog(),
                     "presenter parent unusable: source=%{public}d parent=%{public}d",
                     sourceLayer != nil, sourceParent != nil);
        return NO;
    }
    BOOL sourceUnderHost = hostLayer != nil && PTLayerIsDescendantOf(sourceLayer, hostLayer);
    if (hostLayer == nil) {
        os_log_error(PTCanvasLog(), "host content layer unavailable; mounting presenter on source parent");
    } else if (!sourceUnderHost) {
        os_log_error(PTCanvasLog(), "source layer not under host content layer; mounting presenter on source parent");
    }

    // 清理旧版本挂在宿主根层或 source 同级树上的 presenter，避免旧画面继续叠加。
    [self removePresentersFromLayerTree:hostLayer];
    [self removePresentersFromLayerTree:sourceParent];

    CALayer *presenter = [CALayer layer];
    presenter.name = PTCanvasPresenterName;
    presenter.opaque = YES;
    presenter.masksToBounds = YES;
    presenter.zPosition = sourceLayer.zPosition;
    presenter.contentsGravity = kCAGravityResize;
    presenter.contentsScale = sourceParent.contentsScale > 0.0
        ? sourceParent.contentsScale
        : 1.0;
    presenter.geometryFlipped = sourceParent.geometryFlipped;
    presenter.hidden = YES;

    [sourceParent insertSublayer:presenter above:sourceLayer];
    if (PTLayerIsDescendantOf(presenter, sourceLayer) ||
        !PTLayerIsDescendantOf(presenter, sourceParent)) {
        [presenter removeFromSuperlayer];
        return NO;
    }
    os_log(PTCanvasLog(), "presenter mounted: hostLayer=%{public}d sourceUnderHost=%{public}d",
           hostLayer != nil, sourceUnderHost);

    _sourceLayer = sourceLayer;
    _presenterParentLayer = sourceParent;
    _presenterLayer = presenter;
    _geometryValid = NO;
    _sourceWindowRect = CGRectZero;
    _presenterRect = CGRectZero;
    return YES;
}

- (BOOL)updatePresenterFrame {
    if (_sourceWindow == nil || _sourceLayer == nil ||
        _presenterParentLayer == nil || _presenterLayer == nil) {
        if (_geometryValid) {
            os_log_error(PTCanvasLog(), "presenter geometry invalidated: binding missing");
        }
        _geometryValid = NO;
        _sourceWindowRect = CGRectZero;
        _presenterRect = CGRectZero;
        return NO;
    }
    // 绑定约束只看与 presenter 直接相关的拓扑：source window 的 root layer 未变、
    // presenter 与 source 始终同级。宿主 contentView 的 layer 树关系不作为失效条件。
    if (_sourceWindow.layer != _sourceLayer ||
        _sourceLayer.superlayer != _presenterParentLayer ||
        _presenterLayer.superlayer != _presenterParentLayer ||
        PTLayerIsDescendantOf(_presenterLayer, _sourceLayer) ||
        PTLayerIsDescendantOf(_sourceLayer, _presenterLayer)) {
        // backing layer 被宿主替换后必须重新绑定，不能继续发布旧坐标。
        if (_geometryValid) {
            os_log_error(PTCanvasLog(), "presenter geometry invalidated: layer tree changed");
        }
        _geometryValid = NO;
        _sourceWindowRect = CGRectZero;
        _presenterRect = CGRectZero;
        _presenterLayer.hidden = YES;
        return NO;
    }

    // 两个矩形来自同一帧 layer 几何，分别服务显示和 UIWindow 触控坐标。
    CGRect sourceWindowRect = [_sourceLayer convertRect:_sourceLayer.bounds
                                                 toLayer:_sourceWindow.layer];
    CGRect presenterRect = [_sourceLayer convertRect:_sourceLayer.bounds
                                              toLayer:_presenterParentLayer];
    if (!PTLayerRectIsValid(sourceWindowRect) ||
        !PTLayerRectIsValid(presenterRect)) {
        if (_geometryValid) {
            os_log_error(PTCanvasLog(), "presenter geometry invalidated: rect invalid");
        }
        _geometryValid = NO;
        _sourceWindowRect = CGRectZero;
        _presenterRect = CGRectZero;
        _presenterLayer.hidden = YES;
        return NO;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _presenterLayer.frame = presenterRect;
    _presenterLayer.contentsScale = _presenterParentLayer.contentsScale > 0.0
        ? _presenterParentLayer.contentsScale
        : 1.0;
    [CATransaction commit];

    _sourceWindowRect = sourceWindowRect;
    _presenterRect = presenterRect;
    _geometryValid = YES;
    return YES;
}

- (void)installObservers {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self
               selector:@selector(windowGeometryChanged:)
                   name:@"NSWindowDidResizeNotification"
                 object:_hostWindow];
    [center addObserver:self
               selector:@selector(windowGeometryChanged:)
                   name:@"NSWindowDidEndLiveResizeNotification"
                 object:_hostWindow];
    [center addObserver:self
               selector:@selector(windowGeometryChanged:)
                   name:UIWindowDidBecomeKeyNotification
                 object:_sourceWindow];
}

- (void)removeObservers {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)windowGeometryChanged:(NSNotification *)notification {
    (void)notification;
    [self updatePresenterFrame];
}

- (PTSurfaceRef)surfaceForSlot:(NSUInteger *)slotIndex {
    for (NSUInteger index = 0; index < PTCanvasSurfaceSlotCount; index++) {
        PTCanvasSurfaceSlot *slot = &_slots[index];
        if (slot->surface == NULL ||
            (index != _currentSlot && slot->retireAfterTick <= _displayTick)) {
            if (slot->surface == NULL) {
                slot->surface = PTRenderServerCreateSurface(_canvasWidth, _canvasHeight);
                if (slot->surface == NULL) {
                    continue;
                }
            }
            slot->retireAfterTick = NSUIntegerMax;
            *slotIndex = index;
            return slot->surface;
        }
    }
    return NULL;
}

- (void)publishSurface:(PTSurfaceRef)surface slot:(NSUInteger)slotIndex {
    NSUInteger oldSlot = _currentSlot;

    // 关闭隐式动画，保证画面只在 surface 发布时切换，不产生额外的中间缩放帧。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _presenterLayer.contents = (__bridge id)((CFTypeRef)surface);
    _presenterLayer.hidden = NO;
    [CATransaction commit];

    _currentSlot = slotIndex;
    _slots[slotIndex].retireAfterTick = NSUIntegerMax;
    if (oldSlot != NSNotFound && oldSlot != slotIndex) {
        _slots[oldSlot].retireAfterTick = _displayTick + PTCanvasRetireDelay;
    }
    _consecutiveFailures = 0;
}

- (BOOL)captureFrame {
    if (!_active || !_geometryValid || _sourceLayer == nil ||
        _presenterLayer == nil) {
        return NO;
    }

    NSUInteger slotIndex = NSNotFound;
    PTSurfaceRef surface = [self surfaceForSlot:&slotIndex];
    if (surface == NULL) {
        return NO;
    }

    if (!PTRenderServerRenderLayerFittedIntoSurface(_sourceLayer, surface)) {
        _slots[slotIndex].retireAfterTick = _displayTick + PTCanvasRetireDelay;
        _consecutiveFailures += 1;
        if (_consecutiveFailures == 1) {
            os_log_error(PTCanvasLog(), "render into fixed surface failed");
        }
        if (_consecutiveFailures >= PTCanvasFailureLimit) {
            [self deactivateAfterFailure];
        }
        return NO;
    }

    [self publishSurface:surface slot:slotIndex];
    return YES;
}

- (void)displayLinkTick:(CADisplayLink *)displayLink {
    (void)displayLink;
    if (!_active) {
        return;
    }
    _displayTick += 1;
    if ([self updatePresenterFrame]) {
        [self captureFrame];
    }
}

- (BOOL)startWithSourceWindow:(UIWindow *)sourceWindow
                   hostWindow:(NSObject *)hostWindow
                         width:(NSUInteger)width
                        height:(NSUInteger)height {
    if (_active) {
        if (_geometryValid && _currentSlot != NSNotFound) {
            return [self updateBindingWithSourceWindow:sourceWindow hostWindow:hostWindow];
        }
        [self stop];
    }
    if (sourceWindow == nil || hostWindow == nil || width < 1 || height < 1 ||
        !PTRenderServerScaledCaptureAvailable()) {
        os_log_error(PTCanvasLog(),
                     "start rejected: source=%{public}d host=%{public}d size=%lux%lu scaledCapture=%{public}d",
                     sourceWindow != nil, hostWindow != nil,
                     (unsigned long)width, (unsigned long)height,
                     PTRenderServerScaledCaptureAvailable());
        return NO;
    }

    CALayer *sourceLayer = sourceWindow.layer;
    if (sourceLayer == nil || ![self preparePresenterForSourceLayer:sourceLayer
                                                         hostWindow:hostWindow]) {
        os_log_error(PTCanvasLog(),
                     "start rejected: presenter preparation failed (host content layer mismatch)");
        return NO;
    }

    _sourceWindow = sourceWindow;
    _hostWindow = hostWindow;
    _canvasWidth = width;
    _canvasHeight = height;
    _displayTick = 0;
    _consecutiveFailures = 0;
    _active = YES;
    [self installObservers];

    _displayLink = [CADisplayLink displayLinkWithTarget:self
                                               selector:@selector(displayLinkTick:)];
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    if (![self updatePresenterFrame]) {
        os_log_error(PTCanvasLog(), "start rejected: presenter frame invalid");
        [self stop];
        return NO;
    }
    if (![self captureFrame]) {
        os_log_error(PTCanvasLog(), "start rejected: first capture failed");
        [self stop];
        return NO;
    }
    os_log(PTCanvasLog(), "pipeline started: canvas=%lux%lu",
           (unsigned long)width, (unsigned long)height);
    return YES;
}

- (BOOL)updateBindingWithSourceWindow:(UIWindow *)sourceWindow
                           hostWindow:(NSObject *)hostWindow {
    if (!_active) {
        if (sourceWindow == nil || hostWindow == nil ||
            _canvasWidth < 1 || _canvasHeight < 1) {
            return NO;
        }
        if (!PTSetPinnedDrawableSize(CGSizeMake(_canvasWidth, _canvasHeight))) {
            return NO;
        }
        BOOL started = [self startWithSourceWindow:sourceWindow
                                       hostWindow:hostWindow
                                             width:_canvasWidth
                                            height:_canvasHeight];
        return started;
    }
    if (_sourceWindow == sourceWindow && _hostWindow == hostWindow) {
        if (![self updatePresenterFrame]) {
            [self stop];
            if (!PTSetPinnedDrawableSize(CGSizeMake(_canvasWidth, _canvasHeight))) {
            return NO;
        }
            BOOL started = [self startWithSourceWindow:sourceWindow
                                           hostWindow:hostWindow
                                                 width:_canvasWidth
                                                height:_canvasHeight];
            return started;
        }
        if (_currentSlot == NSNotFound) {
            return [self captureFrame];
        }
        return YES;
    }

    [self stop];
    if (!PTSetPinnedDrawableSize(CGSizeMake(_canvasWidth, _canvasHeight))) {
        return NO;
    }
    BOOL started = [self startWithSourceWindow:sourceWindow
                                   hostWindow:hostWindow
                                         width:_canvasWidth
                                        height:_canvasHeight];
    return started;
}

- (void)deactivateAfterFailure {
    if (_active) {
        os_log_error(PTCanvasLog(),
                     "pipeline deactivated after %lu consecutive render failures (pin kept)",
                     (unsigned long)_consecutiveFailures);
    }
    _active = NO;
    [_displayLink invalidate];
    _displayLink = nil;
    [self removeObservers];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _presenterLayer.hidden = YES;
    _presenterLayer.contents = nil;
    [CATransaction commit];
    [_presenterLayer removeFromSuperlayer];
    _presenterLayer = nil;
    _sourceLayer = nil;
    _presenterParentLayer = nil;
    _geometryValid = NO;
    _sourceWindowRect = CGRectZero;
    _presenterRect = CGRectZero;

    for (NSUInteger index = 0; index < PTCanvasSurfaceSlotCount; index++) {
        PTRenderServerReleaseSurface(_slots[index].surface);
        _slots[index].surface = NULL;
        _slots[index].retireAfterTick = 0;
    }
    _currentSlot = NSNotFound;
    _sourceWindow = nil;
    _hostWindow = nil;
}

- (void)stop {
    if (!_active && _presenterLayer == nil) {
        PTSetPinnedDrawableSize(CGSizeZero);
        return;
    }
    _active = NO;
    [_displayLink invalidate];
    _displayLink = nil;
    [self removeObservers];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _presenterLayer.hidden = YES;
    _presenterLayer.contents = nil;
    [CATransaction commit];
    [_presenterLayer removeFromSuperlayer];
    _presenterLayer = nil;
    _sourceLayer = nil;
    _presenterParentLayer = nil;
    _geometryValid = NO;
    _sourceWindowRect = CGRectZero;
    _presenterRect = CGRectZero;

    for (NSUInteger index = 0; index < PTCanvasSurfaceSlotCount; index++) {
        PTRenderServerReleaseSurface(_slots[index].surface);
        _slots[index].surface = NULL;
        _slots[index].retireAfterTick = 0;
    }
    _currentSlot = NSNotFound;
    _sourceWindow = nil;
    _hostWindow = nil;
    PTSetPinnedDrawableSize(CGSizeZero);
}

- (NSData *)copyCurrentFrameWithWidth:(NSUInteger *)width height:(NSUInteger *)height {
    if (!_active || !_geometryValid || _currentSlot == NSNotFound) {
        return nil;
    }
    PTSurfaceRef surface = _slots[_currentSlot].surface;
    if (surface == NULL) {
        return nil;
    }
    return PTRenderServerCopySurface(surface, width, height);
}

- (BOOL)copyGeometry:(PTCanvasDisplayGeometry *)geometry {
    if (geometry == NULL) {
        return NO;
    }
    geometry->canvasSize = CGSizeZero;
    geometry->sourceWindowRect = CGRectZero;
    geometry->presenterRect = CGRectZero;
    geometry->valid = NO;
    if (!_active || !_geometryValid) {
        return NO;
    }
    geometry->canvasSize = CGSizeMake(_canvasWidth, _canvasHeight);
    geometry->sourceWindowRect = _sourceWindowRect;
    geometry->presenterRect = _presenterRect;
    geometry->valid = YES;
    return YES;
}

@end

static PTCanvasDisplayController *PTSharedCanvasController;

static void PTCanvasPerformOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

BOOL PTCanvasDisplayStart(UIWindow *sourceWindow,
                          NSObject * _Nullable hostWindow,
                          NSUInteger width,
                          NSUInteger height) {
    __block BOOL result = NO;
    PTCanvasPerformOnMain(^{
        if (PTSharedCanvasController == nil) {
            PTSharedCanvasController = [PTCanvasDisplayController new];
        }
        if (!PTSetPinnedDrawableSize(CGSizeMake(width, height))) {
            os_log_error(PTCanvasLog(), "drawable pin failed; fixed surface not started");
            return;
        }
        if (PTSharedCanvasController.active) {
            [PTSharedCanvasController stop];
        }
        result = [PTSharedCanvasController startWithSourceWindow:sourceWindow
                                                      hostWindow:hostWindow
                                                            width:width
                                                           height:height];
    });
    return result;
}

BOOL PTCanvasDisplayUpdateBinding(UIWindow *sourceWindow,
                                  NSObject * _Nullable hostWindow) {
    __block BOOL result = NO;
    PTCanvasPerformOnMain(^{
        result = [PTSharedCanvasController updateBindingWithSourceWindow:sourceWindow
                                                               hostWindow:hostWindow];
    });
    return result;
}

void PTCanvasDisplayStop(void) {
    PTCanvasPerformOnMain(^{
        [PTSharedCanvasController stop];
    });
}

void PTCanvasDisplaySuspend(void) {
    PTCanvasPerformOnMain(^{
        [PTSharedCanvasController deactivateAfterFailure];
    });
}

BOOL PTCanvasDisplayIsActive(void) {
    __block BOOL result = NO;
    PTCanvasPerformOnMain(^{
        result = PTSharedCanvasController.active;
    });
    return result;
}

NSData *PTCanvasDisplayCopyCurrentFrame(NSUInteger * _Nullable width,
                                        NSUInteger * _Nullable height) {
    __block NSData *result = nil;
    PTCanvasPerformOnMain(^{
        result = [PTSharedCanvasController copyCurrentFrameWithWidth:width height:height];
    });
    return result;
}

BOOL PTCanvasDisplayCopyGeometry(PTCanvasDisplayGeometry * _Nullable geometry) {
    __block BOOL result = NO;
    PTCanvasPerformOnMain(^{
        result = [PTSharedCanvasController copyGeometry:geometry];
    });
    return result;
}
