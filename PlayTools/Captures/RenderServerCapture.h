#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 检查 RenderServer 私有符号和 IOSurface 是否已通过运行时解析。
FOUNDATION_EXPORT BOOL PTRenderServerCaptureAvailable(void);

/// 以指定像素尺寸捕获 key window 的完整图层合成结果，返回顶部起始的 BGRA 数据。
/// 不可用或调用失败时返回 nil；必须在主线程调用。
FOUNDATION_EXPORT NSData * _Nullable PTRenderServerCaptureKeyWindow(NSUInteger width,
                                                                    NSUInteger height);

NS_ASSUME_NONNULL_END
