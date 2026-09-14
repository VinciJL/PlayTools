#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 将 CAMetalLayer.drawableSize 固定为指定尺寸，使窗口缩放时游戏渲染分辨率不变。
/// 固定期间强制使用 kCAGravityResize，让 drawable 始终填满图层。
/// 对 CAMetalLayer 对应的游戏视图，将 contentScaleFactor 动态设为固定高度 / 视图高度，
/// 避免 Unity 的渲染和 UI 比例随窗口尺寸变化；传入 CGSizeZero 可解除固定。
/// 未固定时仍会拦截无效 drawableSize，并沿用上一次有效尺寸（默认 1280×720）。
FOUNDATION_EXPORT BOOL PTSetPinnedDrawableSize(CGSize size);

NS_ASSUME_NONNULL_END
