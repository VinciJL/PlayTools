import Foundation
import ObjectiveC.runtime
import UIKit

/// Mode 7 display scaler: the lying scene keeps the game's content at the
/// fixed canvas (the configured resolution, e.g. 1280x720 points), while the
/// real window can be any size. This scales the window's top-level views
/// (the root view controller's view plus any presentation containers, so
/// presented overlays scale too) so the canvas stretches to fill the window,
/// pinned to the top-left corner (CALayer's default anchor point would scale
/// around the center and shift the content).
///
/// View-level transforms (rather than the UIWindow's) are used because the
/// window layer is system-managed and the system's event coordinate
/// conversion does not account for window-level transforms, which breaks
/// hit-testing.
///
/// The render-server capture resets these transforms around the capture, so
/// screenshots still grab the canvas 1:1 regardless of this scaling.
enum CanvasDisplayScaler {
    private static let resizeNotification = Notification.Name("NSWindowDidResizeNotification")
    private static let endResizeNotification = Notification.Name("NSWindowDidEndLiveResizeNotification")
    private static let becomeKeyNotification = Notification.Name("NSWindowDidBecomeKeyNotification")
    private static let windowBecomeKeyNotification = Notification.Name("UIWindowDidBecomeKeyNotification")

    /// The scale currently applied to the canvas (canvas points -> window
    /// points); 1 when the scaler is inactive.
    private(set) static var currentScale: CGFloat = 1

    /// Starts applying the canvas-to-window scale (mode 7 only).
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
        guard let window = PlayScreen.shared.keyWindow,
              let rootView = window.rootViewController?.view,
              let nsWindow = window.nsWindow,
              let frameValue = nsWindow.value(forKey: "frame") as? NSValue else { return }
        let frame = frameValue.cgRectValue
        guard let content = contentRect(of: nsWindow, frame: frame) else { return }
        let canvas = rootView.bounds.size
        guard canvas.width > 0, canvas.height > 0, content.size.width > 0 else { return }
        let scale = content.size.width / canvas.width
        guard scale > 0.01 else { return }
        currentScale = scale
        // Pin the scaling to the view's top-left instead of its center:
        // x' = scale * x + tx, with tx compensating the center anchor
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        transform.tx = (scale - 1) * canvas.width / 2
        transform.ty = (scale - 1) * canvas.height / 2
        // Top-level views: the root view plus presentation containers, so
        // presented overlays (dialogs, web views) scale with the canvas
        let subviews = window.subviews
        let preTransforms = subviews.map { Double($0.transform.a) }
        for subview in subviews where subview.transform != transform {
            subview.transform = transform
        }
        let postTransforms = subviews.map { Double($0.transform.a) }
        window.layer.masksToBounds = false
        logDiagnostics(content: content.size, canvas: canvas, scale: scale,
                       pre: preTransforms, post: postTransforms,
                       window: window, rootView: rootView)
    }

    private static var lastLogged = ""

    /// Temporary diagnostics for the canvas scaling (read /tmp/playscaler.log)
    private static func logDiagnostics(content: CGSize, canvas: CGSize, scale: CGFloat,
                                       pre: [Double], post: [Double],
                                       window: UIWindow, rootView: UIView) {
        let preText = pre.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let postText = post.map { String(format: "%.3f", $0) }.joined(separator: ",")
        // Find the game view: the largest CAMetalLayer-backed view in the tree
        var unitySize = CGSize.zero
        func findGameView(_ view: UIView) {
            if view.layer is CAMetalLayer, view.bounds.width > unitySize.width {
                unitySize = view.bounds.size
            }
            for sub in view.subviews { findGameView(sub) }
        }
        findGameView(window)
        let winBounds = window.bounds.size
        let rootFrame = rootView.frame
        let line = String(format:
            "content=%.0fx%.0f scale=%.4f n=%d pre=[%@] post=[%@] win=%.0fx%.0f root=%.0fx%.0f@%.0f,%.0f unity=%.0fx%.0f\n",
            content.width, content.height, scale, pre.count, preText, postText,
            winBounds.width, winBounds.height,
            rootFrame.size.width, rootFrame.size.height, rootFrame.origin.x, rootFrame.origin.y,
            unitySize.width, unitySize.height)
        guard line != lastLogged else { return }
        lastLogged = line
        let path = "/tmp/playscaler.log"
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        }
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
