import Foundation
import ObjectiveC.runtime
import UIKit

/// mode 7 只追踪固定画布与实时窗口的比例，不修改任何视图变换。
/// 该比例用于把 MAA 画布坐标映射到窗口中的视觉坐标；截图则先捕获窗口合成图，再缩回固定画布。
/// 通过 KVC 和运行时调用读取 AppKit 的 NSWindow，避免游戏侧直接链接 AppKit。
enum CanvasDisplayScaler {
    private static let resizeNotification = Notification.Name("NSWindowDidResizeNotification")
    private static let endResizeNotification = Notification.Name("NSWindowDidEndLiveResizeNotification")
    private static let becomeKeyNotification = Notification.Name("NSWindowDidBecomeKeyNotification")
    private static let windowBecomeKeyNotification = Notification.Name("UIWindowDidBecomeKeyNotification")

    /// 当前窗口宽度 / 固定画布宽度；未启用时为 1。
    private(set) static var currentScale: CGFloat = 1

    static func start() {
        guard PlaySettings.shared.resolution == 7 else { return }
        let center = NotificationCenter.default
        for name in [resizeNotification, endResizeNotification,
                     becomeKeyNotification, windowBecomeKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                update()
            }
        }
        // 使用 common mode，拖动窗口进入 tracking mode 时仍然能刷新比例。
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
        guard PlaySettings.shared.resolution == 7 else { return }
        let canvasWidth = PlaySettings.shared.windowSizeWidth
        guard canvasWidth > 0 else { return }
        guard let window = PlayScreen.shared.keyWindow,
              let nsWindow = window.nsWindow,
              let frameValue = nsWindow.value(forKey: "frame") as? NSValue else { return }
        let frame = frameValue.cgRectValue
        guard let content = contentRect(of: nsWindow, frame: frame) else { return }
        guard content.size.width > 0 else { return }
        currentScale = content.size.width / canvasWidth
    }

    /// 通过运行时调用 `-[NSWindow contentRectForFrameRect:]`，避免引入 AppKit 链接。
    private static func contentRect(of nsWindow: NSObject, frame: CGRect) -> CGRect? {
        guard let windowClass = NSClassFromString("NSWindow") else { return nil }
        let selector = NSSelectorFromString("contentRectForFrameRect:")
        guard let implementation = class_getMethodImplementation(windowClass, selector) else {
            return nil
        }
        typealias ContentRectFn = @convention(c) (AnyObject, Selector, CGRect) -> CGRect
        let function = unsafeBitCast(implementation, to: ContentRectFn.self)
        return function(nsWindow, selector, frame)
    }
}
