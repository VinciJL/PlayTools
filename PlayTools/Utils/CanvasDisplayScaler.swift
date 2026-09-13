import Foundation
import ObjectiveC.runtime
import UIKit

/// Mode 7: tracks the factor between the fixed canvas (the configured
/// resolution, which is also the screenshot resolution) and the live window
/// size. Touch injection multiplies capture coordinates by this factor so
/// touches land at the visual position, and the render-server capture uses
/// the window size to grab the real composite before scaling it back to the
/// canvas.
///
/// The window geometry is read through the NSWindow accessible via KVC (the
/// AppKit-side object exists in this process); notifications are observed by
/// name so no AppKit import is needed.
enum CanvasDisplayScaler {
    private static let resizeNotification = Notification.Name("NSWindowDidResizeNotification")
    private static let endResizeNotification = Notification.Name("NSWindowDidEndLiveResizeNotification")
    private static let becomeKeyNotification = Notification.Name("NSWindowDidBecomeKeyNotification")
    private static let windowBecomeKeyNotification = Notification.Name("UIWindowDidBecomeKeyNotification")

    /// Window width / canvas width; 1 when the scaler is inactive.
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
        // Common mode so the check keeps firing during live resize (the main
        // run loop stays in tracking mode while the window is dragged)
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

    /// Calls `-[NSWindow contentRectForFrameRect:]` through the runtime so no
    /// AppKit linkage is needed on the game side.
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
