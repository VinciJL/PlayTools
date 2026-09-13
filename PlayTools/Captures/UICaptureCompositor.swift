import CoreGraphics
import Foundation
import OSLog
import UIKit

/// Composites the window's UIKit layer tree onto a captured game frame at
/// capture time (CPU) so screenshots contain UIKit content (web views,
/// native overlays) with the same geometry the display shows.
///
/// Earlier iterations rendered the live window tree with CARenderer on the
/// main thread; that stalls the game's player loop, so the compositing is
/// done per capture with `CALayer.render(in:)` instead, mirroring the
/// previously validated overlay path.
final class UICaptureCompositor {
    static let shared = UICaptureCompositor()

    private let logger = Logger(subsystem: "PlayTools", category: "UICapture")

    private init() {}

    /// Draws the key window's layers over a captured frame buffer.
    /// Must be called on the main thread. The buffer holds the game frame in
    /// premultiplied-first BGRA (byte order 32 little), row 0 at the top.
    func compositeOverFrame(width: Int, height: Int, buffer: UnsafeMutableRawPointer) {
        guard let window = PlayScreen.shared.keyWindow else { return }
        let winW = window.bounds.width
        let winH = window.bounds.height
        guard winW > 0, winH > 0 else { return }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 4 * width,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            logger.error("Failed to create overlay context")
            return
        }

        // UIKit's origin is bottom-left while the buffer's first row is the
        // top; flip Y and scale the window's geometry to the frame resolution.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / winW, y: -CGFloat(height) / winH)
        window.layer.render(in: context)
    }
}
