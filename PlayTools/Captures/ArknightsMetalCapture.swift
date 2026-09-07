import IOSurface
import Metal
import OSLog
import QuartzCore

private let logger = Logger(subsystem: "PlayTools", category: "MetalCapture")

final class ArknightsMetalCapture {
    private static let bundleIdentifiers = [
        "com.hypergryph.arknights"
    ]

    private let state = MetalCaptureState()

    static let shared = ArknightsMetalCapture()

    private init() {}

    func capture() async throws -> MetalCapture {
        switch Self.installation {
        case nil: throw MetalCaptureError.disabled
        case false: throw MetalCaptureError.unavailable
        case true: break
        }
        return try await withUnsafeThrowingContinuation { continuation in
            state.register(continuation: continuation)
        }
    }

    static let installation: Bool? = {
        guard PlaySettings.shared.enableMetalCapture else { return nil }
        return shared.installHooks()
    }()

    private func installHooks() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              Self.bundleIdentifiers.contains(bundleIdentifier)
        else {
            return false
        }

        PTInstallFramebufferOnlyOverride()
        PTInstallMetalLayerDrawableSizeFix()

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let commandBufferClass = object_getClass(commandBuffer) else {
            logger.error("Failed to discover the Metal command-buffer class")
            return false
        }

        let commitCallback: PTMetalCommitCallback = { [weak self] commandBuffer in
            self?.observeCommit(commandBuffer)
        }
        let presentCallback: PTMetalDrawableCallback = { [weak self] drawable in
            self?.observePresent(drawable)
        }
        guard PTInstallMetalCaptureHooks(commandBufferClass, commitCallback, presentCallback) else {
            logger.error("Failed to install the Metal capture hooks")
            return false
        }

        return true
    }

    private func observeCommit(_ object: Any) {
        guard let commandBuffer = object as? MTLCommandBuffer else { return }
        state.initialize(commandQueue: commandBuffer.commandQueue)
    }

    private func observePresent(_ object: Any) {
        guard let drawable = object as? CAMetalDrawable else { return }

        let texture = drawable.texture
        guard texture.pixelFormat == .bgra8Unorm,
              texture.sampleCount == 1,
              texture.width > 0, texture.height > 0 else { return }

        guard let continuation = state.takeContinuation() else {
            return
        }

        guard let surface = texture.iosurface else {
            logger.error("Drawable texture has no IOSurface backing")
            continuation.resume(throwing: MetalCaptureError.unavailable)
            return
        }

        let width = texture.width
        let height = texture.height
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let length = bytesPerRow * height

        let kr = IOSurfaceLock(surface, .readOnly, nil)
        guard kr == kIOReturnSuccess else {
            logger.error("IOSurfaceLock failed: \(kr)")
            continuation.resume(throwing: MetalCaptureError.unavailable)
            return
        }

        let base = IOSurfaceGetBaseAddress(surface)

        // If the surface row stride matches width*4, we can hand off the
        // IOSurface memory directly via a no-copy Data wrapper.  Otherwise
        // copy row-by-row to strip the padding.
        let pixelBytes = width * 4
        let data: Data
        if bytesPerRow == pixelBytes {
            data = Data(
                bytesNoCopy: base,
                count: length,
                deallocator: .custom { _, _ in IOSurfaceUnlock(surface, .readOnly, nil) }
            )
        } else {
            let buf = UnsafeMutableRawPointer.allocate(byteCount: pixelBytes * height, alignment: 1)
            for row in 0..<height {
                let src = base.advanced(by: row * bytesPerRow)
                buf.advanced(by: row * pixelBytes).copyMemory(from: src, byteCount: pixelBytes)
            }
            IOSurfaceUnlock(surface, .readOnly, nil)
            data = Data(bytesNoCopy: buf, count: pixelBytes * height, deallocator: .custom { ptr, _ in ptr.deallocate() })
        }

        continuation.resume(returning: .init(
            width: width,
            height: height,
            bytesPerRow: pixelBytes,
            data: data
        ))
    }
}
