import Foundation
import OSLog
import UIKit

/// 固定画布与实时 UIWindow 之间的几何快照，截图和触控必须使用同一份数据。
struct CanvasDisplayGeometry {
    let canvasSize: CGSize
    let windowBounds: CGRect
    let displayRect: CGRect
}

/// mode 7 只改变最终显示层的缩放，不修改 UIKit 视图树或窗口布局。
enum CanvasDisplayScaler {
    private static let resizeNotification = Notification.Name("NSWindowDidResizeNotification")
    private static let endResizeNotification = Notification.Name("NSWindowDidEndLiveResizeNotification")
    private static let becomeKeyNotification = Notification.Name("NSWindowDidBecomeKeyNotification")
    private static let windowBecomeKeyNotification = Notification.Name("UIWindowDidBecomeKeyNotification")

    private(set) static var geometry: CanvasDisplayGeometry?
    private static let geometryLock = NSLock()
    private static let logger = Logger(subsystem: "PlayTools", category: "Scaler")
    // 暂停原因只在变化时输出一次，全部在主线程访问。
    private static var lastSuspendReason: String?

    /// 暂停显示并记录原因（同一原因只打一次），便于和管线日志对照。
    private static func suspend(reason: String) {
        if lastSuspendReason != reason {
            lastSuspendReason = reason
            logger.error("scaler suspend: \(reason)")
        }
        PTCanvasDisplaySuspend()
        setGeometry(nil)
    }

    private static func setGeometry(_ newGeometry: CanvasDisplayGeometry?) {
        geometryLock.lock()
        geometry = newGeometry
        geometryLock.unlock()
    }

    private static func cachedGeometrySnapshot() -> CanvasDisplayGeometry? {
        geometryLock.lock()
        let currentGeometry = geometry
        geometryLock.unlock()
        return currentGeometry
    }

    static func start() {
        guard PlaySettings.shared.enableMode7,
              PlaySettings.shared.resolution == 7 else { return }
        let center = NotificationCenter.default
        for name in [resizeNotification, endResizeNotification,
                     becomeKeyNotification, windowBecomeKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                update()
            }
        }
        // 窗口拖动时进入 tracking mode，common mode 可以继续更新显示矩形。
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            update()
        }
        RunLoop.main.add(timer, forMode: .common)
        update()
        for delay in [0.5, 1.5, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                update()
            }
        }
    }

    static func update() {
        guard PlaySettings.shared.enableMode7,
              PlaySettings.shared.resolution == 7 else {
            PTCanvasDisplayStop()
            setGeometry(nil)
            return
        }
        let canvasSize = CGSize(width: PlaySettings.shared.windowSizeWidth.rounded(),
                                height: PlaySettings.shared.windowSizeHeight.rounded())
        guard canvasSize.width > 0, canvasSize.height > 0,
              let window = PlayScreen.shared.keyWindow else {
            // 暂时拿不到 source window 时只暂停显示，保留 drawable pin。
            suspend(reason: "key window or canvas size missing")
            return
        }

        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            suspend(reason: "window bounds empty")
            return
        }

        guard let hostWindow = window.nsWindow else {
            // 没有宿主窗口时保留 source UIWindow 的实时坐标，供普通截图/触控 fallback 使用。
            setGeometry(CanvasDisplayGeometry(canvasSize: canvasSize,
                                               windowBounds: bounds,
                                               displayRect: bounds))
            return
        }

        // presenter 与触控必须读取同一个 layer 几何快照，不能再次独立计算 aspect-fit。
        guard PTCanvasDisplayUpdateBinding(window, hostWindow) else {
            // RenderServer 暂不可用时，drawable pin 仍让 Unity 保持固定尺寸；显示回退到实时窗口。
            setGeometry(CanvasDisplayGeometry(canvasSize: canvasSize,
                                               windowBounds: bounds,
                                               displayRect: bounds))
            return
        }
        var snapshot = PTCanvasDisplayGeometry()
        guard PTCanvasDisplayCopyGeometry(&snapshot),
              snapshot.valid,
              snapshot.canvasSize.width == canvasSize.width,
              snapshot.canvasSize.height == canvasSize.height,
              snapshot.canvasSize.width > 0,
              snapshot.canvasSize.height > 0,
              snapshot.sourceWindowRect.width > 0,
              snapshot.sourceWindowRect.height > 0 else {
            suspend(reason: "pipeline geometry invalid")
            return
        }

        lastSuspendReason = nil
        setGeometry(CanvasDisplayGeometry(canvasSize: snapshot.canvasSize,
                                           windowBounds: bounds,
                                           displayRect: snapshot.sourceWindowRect))
    }

    private static func canonicalGeometry() -> CanvasDisplayGeometry? {
        guard let cachedGeometry = cachedGeometrySnapshot() else {
            return nil
        }
        var snapshot = PTCanvasDisplayGeometry()
        guard PTCanvasDisplayIsActive(),
              PTCanvasDisplayCopyGeometry(&snapshot),
              snapshot.valid,
              snapshot.canvasSize.width > 0,
              snapshot.canvasSize.height > 0,
              snapshot.sourceWindowRect.width > 0,
              snapshot.sourceWindowRect.height > 0 else {
            return cachedGeometry
        }

        return CanvasDisplayGeometry(
            canvasSize: snapshot.canvasSize,
            windowBounds: cachedGeometry.windowBounds,
            displayRect: snapshot.sourceWindowRect
        )
    }

    /// 将 MAA 固定画布像素映射到游戏 UIWindow 的 points 坐标。
    static func windowPoint(forCanvasPoint point: CGPoint) -> CGPoint? {
        // 触控实时读取 pipeline 快照，避免窗口拖动期间使用过期的缩放矩形。
        guard let geometry = canonicalGeometry(),
              geometry.canvasSize.width > 0,
              geometry.canvasSize.height > 0,
              geometry.displayRect.width > 0,
              geometry.displayRect.height > 0 else { return nil }

        return CGPoint(
            x: geometry.displayRect.minX +
                point.x / geometry.canvasSize.width * geometry.displayRect.width,
            y: geometry.displayRect.minY +
                point.y / geometry.canvasSize.height * geometry.displayRect.height
        )
    }
}
