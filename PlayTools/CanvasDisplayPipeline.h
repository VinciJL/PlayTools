#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 启动固定画布显示：source window 负责合成，host window 负责显示 surface。
FOUNDATION_EXPORT BOOL PTCanvasDisplayStart(UIWindow *sourceWindow,
                                            NSObject * _Nullable hostWindow,
                                            NSUInteger width,
                                            NSUInteger height);

/// 窗口切换后更新绑定；相同窗口不会重启显示管线。
FOUNDATION_EXPORT BOOL PTCanvasDisplayUpdateBinding(UIWindow *sourceWindow,
                                                    NSObject * _Nullable hostWindow);

/// 固定画布、source UIWindow 坐标和 presenter 父层坐标的同一份几何快照。
typedef struct {
    CGSize canvasSize;
    CGRect sourceWindowRect;
    CGRect presenterRect;
    /// 使用 C bool 而非 BOOL，Swift 可直接导入为 Bool，无需再取 boolValue。
    bool valid;
} PTCanvasDisplayGeometry;

/// 复制当前显示绑定的几何快照；无有效绑定时返回 NO。
FOUNDATION_EXPORT BOOL
PTCanvasDisplayCopyGeometry(PTCanvasDisplayGeometry * _Nullable geometry);

/// 停止刷新、移除 presenter 并释放所有 surface。
/// 仅在真正退出显示时调用；会同时清除 drawable pin。
FOUNDATION_EXPORT void PTCanvasDisplayStop(void);

/// 暂停显示：移除 presenter 并释放 surface，但保留 drawable pin。
/// 用于窗口/bounds 暂时不可用的状态，避免旧画面残留又不改变 Unity 渲染分辨率。
FOUNDATION_EXPORT void PTCanvasDisplaySuspend(void);


/// 查询当前固定 surface 是否已经成功发布。
FOUNDATION_EXPORT BOOL PTCanvasDisplayIsActive(void);

/// 复制当前已发布的固定 surface；输出宽高由 surface 实际值回填。
FOUNDATION_EXPORT NSData * _Nullable
PTCanvasDisplayCopyCurrentFrame(NSUInteger * _Nullable width,
                                NSUInteger * _Nullable height);

NS_ASSUME_NONNULL_END
