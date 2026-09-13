import Foundation
import ObjectiveC.runtime
import UIKit

/// Mode 7 display scaler: the lying scene keeps the game's content at the
/// fixed canvas (the configured resolution, e.g. 1280x720 points), while the
/// real window can be any size. This scales the game's UIWindow so the canvas
/// stretches to fill the window, pinned to the window's top-left corner
/// (CALayer's default anchor point would scale around the center and shift
/// the content).
///
/// The real window geometry is read through the NSWindow accessible via KVC
/// (the AppKit-side object exists in this process); notifications are
/// observed by name so no AppKit import is needed.
///
/// The render-server capture ignores the captured root layer's own transform,
/// so screenshots still grab the canvas 1:1 regardless of this scaling.
enum CanvasDisplayScaler {
    private static let resizeNotification = Notification.Name("NSWindowDidResizeNotification")
    private static let becomeKeyNotification = Notification.Name("NSWindowDidBecomeKeyNotification")
    private static let windowBecomeKeyNotification = Notification.Name("UIWindowDidBecomeKeyNotification")

    /// Starts applying the canvas-to-window scale (mode 7 only).
    static func start() {
        guard PlaySettings.shared.resolution == 7 else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: resizeNotification, object: nil, queue: .main) { _ in
            update()
        }
        center.addObserver(forName: becomeKeyNotification, object: nil, queue: .main) { _ in
            update()
        }
        center.addObserver(forName: windowBecomeKeyNotification, object: nil, queue: .main) { _ in
            update()
        }
        update()
        // The window may not be fully set up at launch; re-apply shortly after
        for delay in [0.5, 1.5, 3.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                update()
            }
        }
    }

    static func update() {
        guard PlaySettings.shared.resolution == 7 else { return }
        let canvas = CGSize(width: PlaySettings.shared.windowSizeWidth,
                            height: PlaySettings.shared.windowSizeHeight)
        guard canvas.width > 0, canvas.height > 0 else { return }
        guard let window = PlayScreen.shared.keyWindow,
              let nsWindow = window.nsWindow,
              let frameValue = nsWindow.value(forKey: "frame") as? NSValue else { return }
        let frame = frameValue.cgRectValue
        guard let content = contentRect(of: nsWindow, frame: frame) else { return }
        let scale = content.size.width / canvas.width
        guard scale > 0.01 else { return }
        // Pin the scaling to the layer's top-left instead of its center:
        // x' = scale * x + tx, with tx compensating the center anchor
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        transform.tx = (scale - 1) * canvas.width / 2
        transform.ty = (scale - 1) * canvas.height / 2
        if window.transform == transform { return }
        window.transform = transform
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
