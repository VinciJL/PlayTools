#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PTMetalCommitCallback)(id commandBuffer);
typedef void (^PTMetalDrawableCallback)(id drawable);

/// Installs the public Metal hooks used by the capture pipeline.
/// The drawable hook is installed lazily after the first `nextDrawable` call.
FOUNDATION_EXPORT BOOL PTInstallMetalCaptureHooks(
    Class commandBufferClass,
    PTMetalCommitCallback commitCallback,
    PTMetalDrawableCallback presentCallback
);

/// Forces CAMetalLayer.framebufferOnly to NO so drawable textures can be
/// read by blit encoders. Install before any layer is configured.
FOUNDATION_EXPORT BOOL PTInstallFramebufferOnlyOverride(void);

/// Guards CAMetalLayer.setDrawableSize: against CGSizeZero, substituting
/// the last valid size (default 1280x720) to prevent Metal assertion
/// failures when Unity calls setDrawableSize: during scene teardown.
FOUNDATION_EXPORT BOOL PTInstallMetalLayerDrawableSizeFix(void);

/// Pins CAMetalLayer.drawableSize to a fixed value; every setDrawableSize:
/// call is overridden and the getter reports the pinned size. This keeps the
/// game's render resolution constant while the window is resized (the
/// compositor stretches the drawable to the layer). Pass CGSizeZero to
/// unpin. Installs the drawableSize swizzle if needed.
FOUNDATION_EXPORT BOOL PTSetPinnedDrawableSize(CGSize size);

/// Auto-answers the AppKit "reopen windows?" modal that blocks window
/// materialization after an abnormal exit, preventing Unity from
/// aborting on a 0x0 CAMetalLayer during render init.
FOUNDATION_EXPORT BOOL PTInstallMetalAlertAutoAnswer(void);

NS_ASSUME_NONNULL_END
