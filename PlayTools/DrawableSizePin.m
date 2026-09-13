#import "DrawableSizePin.h"

#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

typedef void (*PTSetDrawableSizeIMP)(id, SEL, CGSize);
typedef void (*PTSetContentsGravityIMP)(id, SEL, id);
typedef CGSize (*PTDrawableSizeIMP)(id, SEL);

static PTSetDrawableSizeIMP PTOriginalSetDrawableSize;
static PTSetContentsGravityIMP PTOriginalSetContentsGravity;
static PTDrawableSizeIMP PTOriginalDrawableSize;
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
