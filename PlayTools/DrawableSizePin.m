#import "DrawableSizePin.h"

#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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
        // Force stretch-to-fill so the fixed-size drawable always covers the
        // (possibly larger or smaller) layer bounds.
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

#pragma mark - Content scale pinning

// Unity derives its render/UI scale from `view.bounds * view.contentScaleFactor`
// (the view's pixel size). While the drawable is pinned, the view keeps tracking
// the resizable window, so the content scale must be derived dynamically as
// `pinned size / view size` to keep Unity's screen size constant at the pinned
// render resolution. Applied only to views backed by a CAMetalLayer (the game
// view), everything else is untouched.

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

    Method setMethod = class_getInstanceMethod(
        [CAMetalLayer class],
        sel_registerName("setDrawableSize:"));
    if (setMethod == NULL) {
        return NO;
    }
    PTOriginalSetDrawableSize =
        (PTSetDrawableSizeIMP)method_getImplementation(setMethod);
    if (PTOriginalSetDrawableSize == NULL) {
        return NO;
    }
    method_setImplementation(setMethod, (IMP)PTDrawableSizeSetter);

    Method getMethod = class_getInstanceMethod(
        [CAMetalLayer class],
        sel_registerName("drawableSize"));
    if (getMethod == NULL) {
        return NO;
    }
    PTOriginalDrawableSize =
        (PTDrawableSizeIMP)method_getImplementation(getMethod);
    if (PTOriginalDrawableSize == NULL) {
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
        }
    }

    PTDrawableSizeFixInstalled = YES;
    return YES;
}

BOOL PTSetPinnedDrawableSize(CGSize size) {
    if (!PTInstallDrawableSizeFix()) {
        return NO;
    }
    PTPinnedDrawableSize = size;
    return YES;
}
