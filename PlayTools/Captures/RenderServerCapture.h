#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// 带变换的渲染变体是否可用；固定画布缩放合成依赖该符号。
FOUNDATION_EXPORT BOOL PTRenderServerScaledCaptureAvailable(void);

/// RenderServer 使用的 IOSurface 不暴露具体框架类型，所有权由下列 API 显式管理。
typedef struct __PTSurface *PTSurfaceRef;

/// 创建用于固定画布的 BGRA IOSurface；返回值由调用方负责释放。
FOUNDATION_EXPORT PTSurfaceRef _Nullable
PTRenderServerCreateSurface(NSUInteger width, NSUInteger height);

/// 将指定 CALayer 树缩放渲染到目标 surface，使整棵树恰好铺满 surface 像素空间。
/// 固定画布路径必须使用该接口，不能用 1:1 版本后再缩放结果。
FOUNDATION_EXPORT BOOL
PTRenderServerRenderLayerFittedIntoSurface(CALayer *layer, PTSurfaceRef surface);

/// 释放由 PTRenderServerCreateSurface 返回的 surface。
FOUNDATION_EXPORT void PTRenderServerReleaseSurface(PTSurfaceRef surface);

/// 复制 surface 的实际像素，输出为顶部起始的 BGRA；调用方可取得实际宽高。
FOUNDATION_EXPORT NSData * _Nullable
PTRenderServerCopySurface(PTSurfaceRef surface,
                          NSUInteger * _Nullable width,
                          NSUInteger * _Nullable height);

NS_ASSUME_NONNULL_END
