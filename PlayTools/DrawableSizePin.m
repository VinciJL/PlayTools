#import "DrawableSizePin.h"

#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

// 诊断日志：pin 的安装结果与尺寸变化，便于确认固定分辨率是否生效。
static os_log_t PTPinLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("PlayTools", "DrawablePin");
    });
    return log;
}

typedef void (*PTSetDrawableSizeIMP)(id, SEL, CGSize);
typedef void (*PTSetContentsGravityIMP)(id, SEL, id);
typedef CGSize (*PTDrawableSizeIMP)(id, SEL);
typedef void (*PTSetContentScaleFactorIMP)(id, SEL, CGFloat);
typedef CGFloat (*PTContentScaleFactorIMP)(id, SEL);

static PTSetDrawableSizeIMP PTOriginalSetDrawableSize;
static PTSetContentsGravityIMP PTOriginalSetContentsGravity;
static PTDrawableSizeIMP PTOriginalDrawableSize;
static PTSetContentScaleFactorIMP PTOriginalSetContentScaleFactor;
static PTContentScaleFactorIMP PTOriginalContentScaleFactor;
static CGSize PTLastValidDrawableSize = {1280.0, 720.0};
static CGSize PTPinnedDrawableSize = {0.0, 0.0};
static BOOL PTDrawableSizeFixInstalled;

static BOOL PTHasPinnedDrawableSize(void) {
    return PTPinnedDrawableSize.width >= 1.0 && PTPinnedDrawableSize.height >= 1.0;
}

static CGSize PTDrawableSizeGetter(id self, SEL selector) {
    if (PTHasPinnedDrawableSize()) {
        return PTPinnedDrawableSize;
    }
    CGSize size = PTOriginalDrawableSize(self, selector);
    if (size.width < 1.0 || size.height < 1.0) {
        return PTLastValidDrawableSize;
    }
    return size;
}

static void PTDrawableSizeSetter(id self, SEL selector, CGSize size) {
    if (PTHasPinnedDrawableSize()) {
        size = PTPinnedDrawableSize;
        // drawable 固定时强制拉伸填充，保证不同窗口尺寸都覆盖完整图层。
        if (PTOriginalSetContentsGravity != NULL) {
            PTOriginalSetContentsGravity(self, sel_registerName("setContentsGravity:"),
                                         kCAGravityResize);
        }
    } else if (size.width < 1.0 || size.height < 1.0) {
        size = PTLastValidDrawableSize;
    } else {
        PTLastValidDrawableSize = size;
    }
    PTOriginalSetDrawableSize(self, selector, size);
}

static void PTContentsGravitySetter(id self, SEL selector, id gravity) {
    if (PTHasPinnedDrawableSize()) {
        gravity = kCAGravityResize;
    }
    PTOriginalSetContentsGravity(self, selector, gravity);
}

#pragma mark - 固定内容缩放

// Unity 的像素尺寸由 view.bounds × contentScaleFactor 决定。
// 窗口可以改变 bounds，但只对 CAMetalLayer 对应的游戏视图动态计算比例，
// 使渲染像素始终保持为配置的固定尺寸，其他 UIKit 视图不受影响。

static BOOL PTViewHostsMetalLayer(id view) {
    return [[(UIView *)view layer] isKindOfClass:[CAMetalLayer class]];
}

static CGFloat PTPinnedContentScaleForView(id view) {
    CGFloat height = [(UIView *)view bounds].size.height;
    if (height < 1.0) {
        return 0.0;
    }
    return PTPinnedDrawableSize.height / height;
}

static CGFloat PTContentScaleFactorGetter(id self, SEL selector) {
    if (PTHasPinnedDrawableSize() && PTViewHostsMetalLayer(self)) {
        CGFloat target = PTPinnedContentScaleForView(self);
        if (target >= 0.01) {
            return target;
        }
    }
    return PTOriginalContentScaleFactor(self, selector);
}

static void PTSetContentScaleFactor(id self, SEL selector, CGFloat value) {
    if (PTHasPinnedDrawableSize() && PTViewHostsMetalLayer(self)) {
        CGFloat target = PTPinnedContentScaleForView(self);
        if (target >= 0.01) {
            value = target;
        }
    }
    PTOriginalSetContentScaleFactor(self, selector, value);
}

static BOOL PTInstallDrawableSizeFix(void) {
    if (PTDrawableSizeFixInstalled) {
        return YES;
    }

    BOOL gravityHooked = NO;
    BOOL csfGetHooked = NO;
    BOOL csfSetHooked = NO;

    Method setMethod = class_getInstanceMethod(
        [CAMetalLayer class],
        sel_registerName("setDrawableSize:"));
    if (setMethod == NULL) {
        os_log_error(PTPinLog(), "pin install failed: setDrawableSize: missing");
        return NO;
    }
    PTOriginalSetDrawableSize =
        (PTSetDrawableSizeIMP)method_getImplementation(setMethod);
    if (PTOriginalSetDrawableSize == NULL) {
        os_log_error(PTPinLog(), "pin install failed: setDrawableSize: implementation missing");
        return NO;
    }
    method_setImplementation(setMethod, (IMP)PTDrawableSizeSetter);

    Method getMethod = class_getInstanceMethod(
        [CAMetalLayer class],
        sel_registerName("drawableSize"));
    if (getMethod == NULL) {
        os_log_error(PTPinLog(), "pin install failed: drawableSize missing");
        return NO;
    }
    PTOriginalDrawableSize =
        (PTDrawableSizeIMP)method_getImplementation(getMethod);
    if (PTOriginalDrawableSize == NULL) {
        os_log_error(PTPinLog(), "pin install failed: drawableSize: implementation missing");
        return NO;
    }
    method_setImplementation(getMethod, (IMP)PTDrawableSizeGetter);

    Method gravityMethod = class_getInstanceMethod(
        [CAMetalLayer class],
        sel_registerName("setContentsGravity:"));
    if (gravityMethod != NULL) {
        PTOriginalSetContentsGravity =
            (PTSetContentsGravityIMP)method_getImplementation(gravityMethod);
        if (PTOriginalSetContentsGravity != NULL) {
            method_setImplementation(gravityMethod, (IMP)PTContentsGravitySetter);
            gravityHooked = YES;
        }
    }

    Method csfGetMethod = class_getInstanceMethod(
        [UIView class],
        sel_registerName("contentScaleFactor"));
    if (csfGetMethod != NULL) {
        PTOriginalContentScaleFactor =
            (PTContentScaleFactorIMP)method_getImplementation(csfGetMethod);
        if (PTOriginalContentScaleFactor != NULL) {
            method_setImplementation(csfGetMethod, (IMP)PTContentScaleFactorGetter);
            csfGetHooked = YES;
        }
    }

    Method csfSetMethod = class_getInstanceMethod(
        [UIView class],
        sel_registerName("setContentScaleFactor:"));
    if (csfSetMethod != NULL) {
        PTOriginalSetContentScaleFactor =
            (PTSetContentScaleFactorIMP)method_getImplementation(csfSetMethod);
        if (PTOriginalSetContentScaleFactor != NULL) {
            method_setImplementation(csfSetMethod, (IMP)PTSetContentScaleFactor);
            csfSetHooked = YES;
        }
    }

    PTDrawableSizeFixInstalled = YES;
    // 记录每个 hook 是否装成功：contentScaleFactor 只覆盖 Metal 视图，其他 UIKit
    // 视图仍然按窗口尺寸绘制，这里的结果能确认覆盖范围是否符合预期。
    os_log(PTPinLog(),
           "drawable pin installed: drawableSizeHook=1 gravityHook=%{public}d csfGetHook=%{public}d csfSetHook=%{public}d",
           gravityHooked, csfGetHooked, csfSetHooked);
    return YES;
}

BOOL PTSetPinnedDrawableSize(CGSize size) {
    if (!PTInstallDrawableSizeFix()) {
        return NO;
    }
    if (!CGSizeEqualToSize(PTPinnedDrawableSize, size)) {
        os_log(PTPinLog(), "pinned drawable size -> %{public}.0fx%{public}.0f",
               size.width, size.height);
    }
    PTPinnedDrawableSize = size;
    return YES;
}
