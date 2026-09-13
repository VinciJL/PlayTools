#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether the render-server capture path is available (private QuartzCore
/// symbols and the IOSurface framework resolved at runtime).
FOUNDATION_EXPORT BOOL PTRenderServerCaptureAvailable(void);

/// Captures the key window's layer subtree (game Metal content, UIKit layers
/// and cross-process content such as web views) at the given pixel size via
/// CARenderServerRenderLayer, so one composited image is produced without
/// re-rendering anything. Returns a BGRA (premultiplied, byte order 32
/// little) buffer, or nil when the path is unavailable or the call fails.
/// Must be called on the main thread.
FOUNDATION_EXPORT NSData * _Nullable PTRenderServerCaptureKeyWindow(NSUInteger width,
                                                                    NSUInteger height);

NS_ASSUME_NONNULL_END
