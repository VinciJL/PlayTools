#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Pins CAMetalLayer.drawableSize to a fixed value: every setDrawableSize:
/// call is overridden and the getter reports the pinned size, so the game's
/// render resolution stays constant while the window is resized. While
/// pinned, contentsGravity is forced to kCAGravityResize so the fixed-size
/// drawable stretches to fill the layer bounds. Pass CGSizeZero to unpin.
///
/// When no size is pinned, this also guards against CGSizeZero being set
/// (substituting the last valid size, default 1280x720) to prevent Metal
/// assertion failures when the game resets the layer during scene teardown.
FOUNDATION_EXPORT BOOL PTSetPinnedDrawableSize(CGSize size);

NS_ASSUME_NONNULL_END
