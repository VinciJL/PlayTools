#import "MetalCaptureHook.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <QuartzCore/CAMetalLayer.h>

#import <stdatomic.h>
#import <string.h>

typedef void (*PTMetalPresentIMP)(id, SEL, id);
typedef void (*PTMetalTimedPresentIMP)(id, SEL, id, double);
typedef void (*PTMetalPresentOptionsIMP)(id, SEL, id, unsigned long);
typedef void (*PTMetalDrawableTimedPresentIMP)(id, SEL, double);

static PTMetalPresentIMP PTOriginalPresent;
static PTMetalTimedPresentIMP PTOriginalPresentAtTime;
static PTMetalTimedPresentIMP PTOriginalPresentAfterMinimumDuration;
static PTMetalPresentIMP PTOriginalDrawablePresent;
static PTMetalDrawableTimedPresentIMP PTOriginalDrawablePresentAtTime;
static PTMetalDrawableTimedPresentIMP PTOriginalDrawablePresentAfterMinimumDuration;
static PTMetalPresentOptionsIMP PTOriginalPresentOptions;
static PTMetalPresentHookCallback PTPresentCallback;
static Class PTPresentClass;
static Class PTTimedPresentClass;
static Class PTDrawablePresentClass;
static Class PTDrawableTimedPresentClass;
static Class PTPresentOptionsClass;
static BOOL PTAtTimeInstalled;
static BOOL PTAfterMinimumDurationInstalled;
static BOOL PTDrawableAtTimeInstalled;
static BOOL PTDrawableAfterMinimumDurationInstalled;
static BOOL PTPresentOptionsInstalled;
static _Atomic(bool) PTLoggedPresentEntry;

static void PTLogPresentEntry(id self, SEL selector, id drawable) {
    if (!atomic_exchange(&PTLoggedPresentEntry, true)) {
        os_log_t logger = os_log_create("com.playcover.PlayTools", "metal-capture");
        os_log_info(
            logger,
            "event=present-enter concreteClass=%{public}s selector=%{public}s commandBuffer=%p drawable=%p",
            class_getName(object_getClass(self)),
            sel_getName(selector),
            (__bridge const void *)self,
            (__bridge const void *)drawable
        );
    }
}

static void PTMetalPresent(id self, SEL selector, id drawable) {
    PTLogPresentEntry(self, selector, drawable);

    PTMetalPresentHookCallback callback = PTPresentCallback;
    if (callback != nil) {
        callback(self, drawable);
    }

    PTMetalPresentIMP original = PTOriginalPresent;
    if (original != NULL) {
        original(self, selector, drawable);
    }
}

static void PTMetalPresentAtTime(id self, SEL selector, id drawable, double time) {
    PTLogPresentEntry(self, selector, drawable);

    PTMetalPresentHookCallback callback = PTPresentCallback;
    if (callback != nil) {
        callback(self, drawable);
    }

    PTMetalTimedPresentIMP original = PTOriginalPresentAtTime;
    if (original != NULL) {
        original(self, selector, drawable, time);
    }
}

static void PTMetalPresentAfterMinimumDuration(id self,
                                               SEL selector,
                                               id drawable,
                                               double duration) {
    PTLogPresentEntry(self, selector, drawable);

    PTMetalPresentHookCallback callback = PTPresentCallback;
    if (callback != nil) {
        callback(self, drawable);
    }

    PTMetalTimedPresentIMP original = PTOriginalPresentAfterMinimumDuration;
    if (original != NULL) {
        original(self, selector, drawable, duration);
    }
}

static void PTMetalDrawablePresent(id self, SEL selector, id unused) {
    PTLogPresentEntry(self, selector, self);

    PTMetalPresentHookCallback callback = PTPresentCallback;
    if (callback != nil) {
        callback(self, self);
    }

    PTMetalPresentIMP original = PTOriginalDrawablePresent;
    if (original != NULL) {
        original(self, selector, nil);
    }
}

static void PTMetalDrawablePresentAtTime(id self, SEL selector, double time) {
    PTLogPresentEntry(self, selector, self);

    PTMetalPresentHookCallback callback = PTPresentCallback;
    if (callback != nil) {
        callback(self, self);
    }

    PTMetalDrawableTimedPresentIMP original = PTOriginalDrawablePresentAtTime;
    if (original != NULL) {
        original(self, selector, time);
    }
}

static void PTMetalDrawablePresentAfterMinimumDuration(id self, SEL selector, double duration) {
    PTLogPresentEntry(self, selector, self);

    PTMetalPresentHookCallback callback = PTPresentCallback;
    if (callback != nil) {
        callback(self, self);
    }

    PTMetalDrawableTimedPresentIMP original = PTOriginalDrawablePresentAfterMinimumDuration;
    if (original != NULL) {
        original(self, selector, duration);
    }
}

static void PTMetalPresentOptions(id self, SEL selector, id drawable, unsigned long options) {
    PTLogPresentEntry(self, selector, drawable);

    PTMetalPresentHookCallback callback = PTPresentCallback;
    if (callback != nil) {
        callback(self, drawable);
    }

    PTMetalPresentOptionsIMP original = PTOriginalPresentOptions;
    if (original != NULL) {
        original(self, selector, drawable, options);
    }
}

static BOOL PTClassDefinesSelector(Class class, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(class, &count);
    BOOL definesSelector = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            definesSelector = YES;
            break;
        }
    }
    free(methods);
    return definesSelector;
}

static BOOL PTPrepareMethod(Class concreteClass,
                            SEL selector,
                            const char *expectedTypes,
                            Method *methodOut) {
    Method inheritedMethod = class_getInstanceMethod(concreteClass, selector);
    if (inheritedMethod == NULL) {
        return NO;
    }

    const char *types = method_getTypeEncoding(inheritedMethod);
    if (types == NULL || strcmp(types, expectedTypes) != 0) {
        return NO;
    }

    if (!PTClassDefinesSelector(concreteClass, selector)) {
        if (!class_addMethod(concreteClass,
                             selector,
                             method_getImplementation(inheritedMethod),
                             types)) {
            return NO;
        }
    }

    Method method = class_getInstanceMethod(concreteClass, selector);
    if (method == NULL) {
        return NO;
    }
    *methodOut = method;
    return YES;
}

BOOL PTInstallMetalPresentHook(Class concreteClass, PTMetalPresentHookCallback callback) {
    if (concreteClass == Nil || callback == nil) {
        return NO;
    }

    @synchronized ([NSObject class]) {
        if (PTPresentClass != Nil) {
            return PTPresentClass == concreteClass;
        }

        SEL selector = sel_registerName("presentDrawable:");
        Method method = NULL;
        if (!PTPrepareMethod(concreteClass, selector, "v24@0:8@16", &method)) {
            return NO;
        }

        PTOriginalPresent = (PTMetalPresentIMP)method_getImplementation(method);
        if (PTOriginalPresent == NULL) {
            return NO;
        }

        PTPresentCallback = [callback copy];
        PTPresentClass = concreteClass;
        method_setImplementation(method, (IMP)PTMetalPresent);
        return YES;
    }
}

BOOL PTInstallMetalTimedPresentHook(Class concreteClass,
                                     SEL selector,
                                     PTMetalPresentHookCallback callback) {
    if (concreteClass == Nil || selector == NULL || callback == nil) {
        return NO;
    }

    SEL atTimeSelector = sel_registerName("presentDrawable:atTime:");
    SEL afterMinimumDurationSelector = sel_registerName("presentDrawable:afterMinimumDuration:");
    if (selector != atTimeSelector && selector != afterMinimumDurationSelector) {
        return NO;
    }

    @synchronized ([NSObject class]) {
        if (PTTimedPresentClass != Nil && PTTimedPresentClass != concreteClass) {
            return NO;
        }
        if (selector == atTimeSelector && PTAtTimeInstalled) {
            return PTTimedPresentClass == concreteClass;
        }
        if (selector == afterMinimumDurationSelector && PTAfterMinimumDurationInstalled) {
            return PTTimedPresentClass == concreteClass;
        }

        Method method = NULL;
        if (!PTPrepareMethod(concreteClass, selector, "v32@0:8@16d24", &method)) {
            return NO;
        }

        PTMetalTimedPresentIMP original = (PTMetalTimedPresentIMP)method_getImplementation(method);
        if (original == NULL) {
            return NO;
        }

        PTPresentCallback = [callback copy];
        PTTimedPresentClass = concreteClass;
        if (selector == atTimeSelector) {
            PTOriginalPresentAtTime = original;
            PTAtTimeInstalled = YES;
            method_setImplementation(method, (IMP)PTMetalPresentAtTime);
        } else {
            PTOriginalPresentAfterMinimumDuration = original;
            PTAfterMinimumDurationInstalled = YES;
            method_setImplementation(method, (IMP)PTMetalPresentAfterMinimumDuration);
        }
        return YES;
    }
}

BOOL PTInstallMetalDrawablePresentHook(Class concreteClass, PTMetalPresentHookCallback callback) {
    if (concreteClass == Nil || callback == nil) {
        return NO;
    }

    SEL selector = sel_registerName("present");
    @synchronized ([NSObject class]) {
        if (PTDrawablePresentClass != Nil) {
            return PTDrawablePresentClass == concreteClass;
        }

        Method method = NULL;
        if (!PTPrepareMethod(concreteClass, selector, "v16@0:8", &method)) {
            return NO;
        }

        PTOriginalDrawablePresent = (PTMetalPresentIMP)method_getImplementation(method);
        if (PTOriginalDrawablePresent == NULL) {
            return NO;
        }

        PTPresentCallback = [callback copy];
        PTDrawablePresentClass = concreteClass;
        method_setImplementation(method, (IMP)PTMetalDrawablePresent);
        return YES;
    }
}

BOOL PTInstallMetalTimedDrawablePresentHook(Class concreteClass,
                                            SEL selector,
                                            PTMetalPresentHookCallback callback) {
    if (concreteClass == Nil || selector == NULL || callback == nil) {
        return NO;
    }

    SEL atTimeSelector = sel_registerName("presentAtTime:");
    SEL afterMinimumDurationSelector = sel_registerName("presentAfterMinimumDuration:");
    if (selector != atTimeSelector && selector != afterMinimumDurationSelector) {
        return NO;
    }

    @synchronized ([NSObject class]) {
        if (PTDrawableTimedPresentClass != Nil && PTDrawableTimedPresentClass != concreteClass) {
            return NO;
        }
        if (selector == atTimeSelector && PTDrawableAtTimeInstalled) {
            return PTDrawableTimedPresentClass == concreteClass;
        }
        if (selector == afterMinimumDurationSelector && PTDrawableAfterMinimumDurationInstalled) {
            return PTDrawableTimedPresentClass == concreteClass;
        }

        Method method = NULL;
        if (!PTPrepareMethod(concreteClass, selector, "v24@0:8d16", &method)) {
            return NO;
        }

        PTMetalDrawableTimedPresentIMP original =
            (PTMetalDrawableTimedPresentIMP)method_getImplementation(method);
        if (original == NULL) {
            return NO;
        }

        PTPresentCallback = [callback copy];
        PTDrawableTimedPresentClass = concreteClass;
        if (selector == atTimeSelector) {
            PTOriginalDrawablePresentAtTime = original;
            PTDrawableAtTimeInstalled = YES;
            method_setImplementation(method, (IMP)PTMetalDrawablePresentAtTime);
        } else {
            PTOriginalDrawablePresentAfterMinimumDuration = original;
            PTDrawableAfterMinimumDurationInstalled = YES;
            method_setImplementation(method, (IMP)PTMetalDrawablePresentAfterMinimumDuration);
        }
        return YES;
    }
}

BOOL PTInstallMetalPresentOptionsHook(Class concreteClass, PTMetalPresentHookCallback callback) {
    if (concreteClass == Nil || callback == nil) {
        return NO;
    }

    SEL selector = sel_registerName("presentDrawable:options:");
    @synchronized ([NSObject class]) {
        if (PTPresentOptionsClass != Nil) {
            return PTPresentOptionsClass == concreteClass;
        }

        Method method = NULL;
        if (!PTPrepareMethod(concreteClass, selector, "v32@0:8@16@24", &method)) {
            return NO;
        }

        PTOriginalPresentOptions = (PTMetalPresentOptionsIMP)method_getImplementation(method);
        if (PTOriginalPresentOptions == NULL) {
            return NO;
        }

        PTPresentCallback = [callback copy];
        PTPresentOptionsClass = concreteClass;
        method_setImplementation(method, (IMP)PTMetalPresentOptions);
        return YES;
    }
}

// --- CAMetalLayer setDrawableSize: fix ---
//
// When the UIWindow is not yet materialized (scene race after an abnormal
// exit), Unity calls setDrawableSize: with 0x0; CAMetalLayer ignores the
// call and leaves drawableSize at 0x0, which makes Unity create a zero-size
// texture and abort inside Metal's descriptor validation. Substitute the
// last valid size (default 1280x720) only for the degenerate case; all other
// sizes pass through untouched.

typedef void (*PTMetalLayerSetDrawableSizeIMP)(id, SEL, CGSize);

static PTMetalLayerSetDrawableSizeIMP PTOriginalLayerSetDrawableSize;
static CGSize (*PTOriginalLayerDrawableSize)(id, SEL);
static CGSize PTLayerLastValidSize = {1280.0, 720.0};
static _Atomic(bool) PTLoggedLayerSizeFix;
static _Atomic(bool) PTLayerSizeFixInstalled;

static CGSize PTMetalLayerDrawableSize(id self, SEL selector) {
    CGSize size = PTOriginalLayerDrawableSize(self, selector);
    if (size.width < 1.0 || size.height < 1.0) {
        return PTLayerLastValidSize;
    }
    return size;
}

static void PTMetalLayerSetDrawableSize(id self, SEL selector, CGSize size) {
    if (size.width < 1.0 || size.height < 1.0) {
        CGSize substituted = PTLayerLastValidSize;
        if (!atomic_exchange(&PTLoggedLayerSizeFix, true)) {
            os_log_info(
                os_log_create("com.playcover.PlayTools", "metal-capture"),
                "event=layer-size-fix original=%.0fx%.0f applied=%.0fx%.0f",
                size.width,
                size.height,
                substituted.width,
                substituted.height
            );
        }
        size = substituted;
    } else {
        PTLayerLastValidSize = size;
    }
    PTOriginalLayerSetDrawableSize(self, selector, size);
}

BOOL PTInstallMetalLayerDrawableSizeFix(void) {
    if (atomic_load(&PTLayerSizeFixInstalled)) {
        return YES;
    }
    Method method = class_getInstanceMethod(
        [CAMetalLayer class],
        sel_registerName("setDrawableSize:")
    );
    if (method == NULL) {
        return NO;
    }
    PTOriginalLayerSetDrawableSize =
        (PTMetalLayerSetDrawableSizeIMP)method_getImplementation(method);
    if (PTOriginalLayerSetDrawableSize == NULL) {
        return NO;
    }
    method_setImplementation(method, (IMP)PTMetalLayerSetDrawableSize);

    Method sizeMethod = class_getInstanceMethod(
        [CAMetalLayer class],
        sel_registerName("drawableSize")
    );
    if (sizeMethod == NULL) {
        return NO;
    }
    PTOriginalLayerDrawableSize = (CGSize (*)(id, SEL))method_getImplementation(sizeMethod);
    if (PTOriginalLayerDrawableSize == NULL) {
        return NO;
    }
    method_setImplementation(sizeMethod, (IMP)PTMetalLayerDrawableSize);

    atomic_store(&PTLayerSizeFixInstalled, true);
    return YES;
}

__attribute__((constructor)) static void PTMetalLayerSizeFixAutoInstall(void) {
    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
    if (![identifier isEqualToString:@"com.hypergryph.arknights"]) {
        return;
    }
    PTInstallMetalLayerDrawableSizeFix();
}

// --- NSAlert runModal: auto-answer for the crash-history restoration prompt ---
//
// After an abnormal exit, AppKit shows a modal alert before window
// restoration ("Do you want to try reopening its windows again?"). The modal
// blocks window creation while UIKit still runs Unity's render init, which
// then aborts on the 0x0 layer. Auto-answer the prompt with the first button
// ("Reopen") without showing UI, so restoration completes before Unity init.

static NSInteger (*PTOriginalAlertRunModal)(id, SEL);
static _Atomic(bool) PTAlertAnswerInstalled;
static _Atomic(bool) PTLoggedAlertAnswer;

typedef NSString *(*PTMsgSendStringFn)(id, SEL);

static NSInteger PTMetalAlertRunModal(id self, SEL selector) {
    SEL messageSel = sel_registerName("messageText");
    if ([self respondsToSelector:messageSel]) {
        PTMsgSendStringFn messageFn = (PTMsgSendStringFn)(void *)objc_msgSend;
        NSString *message = messageFn(self, messageSel);
        if (message != nil &&
            ([message containsString:@"reopening its windows"] ||
             [message containsString:@"重新打开它的窗口"])) {
            if (!atomic_exchange(&PTLoggedAlertAnswer, true)) {
                os_log_info(
                    os_log_create("com.playcover.PlayTools", "metal-capture"),
                    "event=alert-auto-answer response=reopen"
                );
            }
            return 1000; /* NSAlertFirstButtonReturn */
        }
    }
    return PTOriginalAlertRunModal(self, selector);
}

static BOOL PTInstallMetalAlertAutoAnswer(void) {
    if (atomic_load(&PTAlertAnswerInstalled)) {
        return YES;
    }
    Class alertClass = objc_getClass("NSAlert");
    if (alertClass == Nil) {
        return NO;
    }
    Method method = class_getInstanceMethod(alertClass, sel_registerName("runModal"));
    if (method == NULL) {
        return NO;
    }
    PTOriginalAlertRunModal = (NSInteger (*)(id, SEL))method_getImplementation(method);
    if (PTOriginalAlertRunModal == NULL) {
        return NO;
    }
    method_setImplementation(method, (IMP)PTMetalAlertRunModal);
    atomic_store(&PTAlertAnswerInstalled, true);
    return YES;
}

__attribute__((constructor)) static void PTMetalAlertAutoAnswerInstall(void) {
    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
    if (![identifier isEqualToString:@"com.hypergryph.arknights"]) {
        return;
    }
    PTInstallMetalAlertAutoAnswer();
}
