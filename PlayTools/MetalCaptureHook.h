#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PTMetalPresentHookCallback)(id commandBuffer, id drawable);

FOUNDATION_EXPORT BOOL PTInstallMetalPresentHook(Class concreteClass,
                                                  PTMetalPresentHookCallback callback);

FOUNDATION_EXPORT BOOL PTInstallMetalTimedPresentHook(Class concreteClass,
                                                       SEL selector,
                                                       PTMetalPresentHookCallback callback);

FOUNDATION_EXPORT BOOL PTInstallMetalDrawablePresentHook(Class concreteClass,
                                                          PTMetalPresentHookCallback callback);

FOUNDATION_EXPORT BOOL PTInstallMetalTimedDrawablePresentHook(Class concreteClass,
                                                               SEL selector,
                                                               PTMetalPresentHookCallback callback);

FOUNDATION_EXPORT BOOL PTInstallMetalPresentOptionsHook(Class concreteClass,
                                                         PTMetalPresentHookCallback callback);

FOUNDATION_EXPORT BOOL PTInstallMetalLayerDrawableSizeFix(void);

NS_ASSUME_NONNULL_END
