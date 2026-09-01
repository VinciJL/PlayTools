#if PLAYTOOLS_METAL_PROBE
import Darwin
import Foundation
import Metal
import ObjectiveC.runtime
import OSLog
import QuartzCore
import UIKit

private struct MetalDrawableSnapshot {
    let uptimeNanos: UInt64
    let threadID: UInt64
    let layerID: UInt
    let layerClass: String
    let contentsScale: Double
    let drawableWidth: Double
    let drawableHeight: Double
    let layerPixelFormat: UInt
    let framebufferOnly: Bool
    let maximumDrawableCount: Int
    let presentsWithTransaction: Bool
    let drawableClass: String
    let textureClass: String
    let textureWidth: Int
    let textureHeight: Int
    let texturePixelFormat: UInt
    let textureSampleCount: Int
    let textureStorageMode: UInt
    let textureUsage: UInt
}

final class ArknightsMetalProbe {
    private static let targetBundleIdentifier = "com.hypergryph.arknights"
    private static let nextDrawableSelector = Selector(("nextDrawable"))
    private static let presentDrawableSelector = Selector(("presentDrawable:"))

    private let logger = Logger(subsystem: "com.playcover.PlayTools", category: "metal-probe")
    private let logQueue = DispatchQueue(label: "com.playcover.PlayTools.metal-probe.log")
    private var sampleLock = os_unfair_lock_s()
    private var lastSampleNanos: UInt64 = 0
    private var hookInstalled = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    static let shared = ArknightsMetalProbe()

    static func install() {
        shared.installIfNeeded()
    }

    private func installIfNeeded() {
        guard Bundle.main.bundleIdentifier == Self.targetBundleIdentifier else { return }

        logQueue.async { [logger] in
            logger.info("event=gate result=pass")
        }
        installLifecycleObservers()
        installNextDrawableHook(retriesRemaining: 3)
    }

    private func installLifecycleObservers() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = NotificationCenter.default
            self.lifecycleObservers.append(
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    self?.logLifecycle("background")
                }
            )
            self.lifecycleObservers.append(
                center.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    self?.logLifecycle("foreground")
                }
            )
        }
    }

    private func installNextDrawableHook(retriesRemaining: Int) {
        guard !hookInstalled else { return }

        guard let method = class_getInstanceMethod(CAMetalLayer.self, Self.nextDrawableSelector) else {
            if retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.installNextDrawableHook(retriesRemaining: retriesRemaining - 1)
                }
            } else {
                logQueue.async { [logger] in
                    logger.error("event=hook result=missing selector=nextDrawable")
                }
            }
            return
        }

        let originalImplementation = method_getImplementation(method)
        let original: @convention(c) (CAMetalLayer, Selector) -> CAMetalDrawable? =
            unsafeBitCast(originalImplementation, to: (@convention(c) (CAMetalLayer, Selector) -> CAMetalDrawable?).self)
        let selector = Self.nextDrawableSelector
        let replacement: @convention(block) (CAMetalLayer) -> CAMetalDrawable? = { [weak self] layer in
            let drawable = original(layer, selector)
            self?.record(layer: layer, drawable: drawable)
            return drawable
        }

        method_setImplementation(method, imp_implementationWithBlock(replacement))
        hookInstalled = true

        let nextEncoding: String
        if let types = method_getTypeEncoding(method) {
            nextEncoding = String(cString: types)
        } else {
            nextEncoding = "missing-method"
        }
        let presentEncoding = Self.methodEncoding(
            protocolName: "MTLCommandBuffer",
            selector: Self.presentDrawableSelector
        )
        logQueue.async { [logger] in
            logger.info(
                "event=hook result=installed nextEncoding=\(nextEncoding, privacy: .public) presentEncoding=\(presentEncoding, privacy: .public)"
            )
        }
    }

    private static func methodEncoding(protocolName: String, selector: Selector) -> String {
        let protocolObject = protocolName.withCString { objc_getProtocol($0) }
        guard let protocolObject else { return "missing-protocol" }
        let description = protocol_getMethodDescription(protocolObject, selector, true, true)
        guard let types = description.types else { return "missing-method" }
        return String(cString: types)
    }

    private func record(layer: CAMetalLayer, drawable: CAMetalDrawable?) {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard shouldSample(now: now) else { return }

        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)

        let layerID = UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())
        let layerClass = String(cString: class_getName(type(of: layer)))
        let drawableSize = layer.drawableSize
        let maximumDrawableCount = layer.responds(to: Selector(("maximumDrawableCount")))
            ? layer.maximumDrawableCount
            : 0
        let presentsWithTransaction = layer.responds(to: Selector(("presentsWithTransaction")))
            ? layer.presentsWithTransaction
            : false

        var snapshot = MetalDrawableSnapshot(
            uptimeNanos: now,
            threadID: threadID,
            layerID: layerID,
            layerClass: layerClass,
            contentsScale: Double(layer.contentsScale),
            drawableWidth: drawableSize.width,
            drawableHeight: drawableSize.height,
            layerPixelFormat: UInt(layer.pixelFormat.rawValue),
            framebufferOnly: layer.framebufferOnly,
            maximumDrawableCount: maximumDrawableCount,
            presentsWithTransaction: presentsWithTransaction,
            drawableClass: "nil",
            textureClass: "nil",
            textureWidth: 0,
            textureHeight: 0,
            texturePixelFormat: 0,
            textureSampleCount: 0,
            textureStorageMode: 0,
            textureUsage: 0
        )

        if let drawable = drawable {
            let texture = drawable.texture
            snapshot = MetalDrawableSnapshot(
                uptimeNanos: now,
                threadID: threadID,
                layerID: layerID,
                layerClass: layerClass,
                contentsScale: Double(layer.contentsScale),
                drawableWidth: drawableSize.width,
                drawableHeight: drawableSize.height,
                layerPixelFormat: UInt(layer.pixelFormat.rawValue),
                framebufferOnly: layer.framebufferOnly,
                maximumDrawableCount: maximumDrawableCount,
                presentsWithTransaction: presentsWithTransaction,
                drawableClass: String(describing: type(of: drawable)),
                textureClass: String(describing: type(of: texture)),
                textureWidth: texture.width,
                textureHeight: texture.height,
                texturePixelFormat: UInt(texture.pixelFormat.rawValue),
                textureSampleCount: texture.sampleCount,
                textureStorageMode: UInt(texture.storageMode.rawValue),
                textureUsage: UInt(texture.usage.rawValue)
            )
        }

        logQueue.async { [logger] in
            logger.info(
                "event=drawable uptimeNanos=\(snapshot.uptimeNanos, privacy: .public) threadID=\(snapshot.threadID, privacy: .public) layerID=\(snapshot.layerID, privacy: .public) layerClass=\(snapshot.layerClass, privacy: .public) scale=\(snapshot.contentsScale, privacy: .public) drawable=\(snapshot.drawableWidth, privacy: .public)x\(snapshot.drawableHeight, privacy: .public) layerPixelFormat=\(snapshot.layerPixelFormat, privacy: .public) framebufferOnly=\(snapshot.framebufferOnly, privacy: .public) maximumDrawableCount=\(snapshot.maximumDrawableCount, privacy: .public) presentsWithTransaction=\(snapshot.presentsWithTransaction, privacy: .public) drawableClass=\(snapshot.drawableClass, privacy: .public) textureClass=\(snapshot.textureClass, privacy: .public) texture=\(snapshot.textureWidth, privacy: .public)x\(snapshot.textureHeight, privacy: .public) texturePixelFormat=\(snapshot.texturePixelFormat, privacy: .public) sampleCount=\(snapshot.textureSampleCount, privacy: .public) storageMode=\(snapshot.textureStorageMode, privacy: .public) usage=\(snapshot.textureUsage, privacy: .public)"
            )
        }
    }

    private func shouldSample(now: UInt64) -> Bool {
        guard os_unfair_lock_trylock(&sampleLock) else { return false }
        defer { os_unfair_lock_unlock(&sampleLock) }

        guard now >= lastSampleNanos, now - lastSampleNanos >= 1_000_000_000 else { return false }
        lastSampleNanos = now
        return true
    }

    private func logLifecycle(_ event: String) {
        logQueue.async { [logger] in
            logger.info("event=lifecycle state=\(event, privacy: .public)")
        }
    }
}
#else
final class ArknightsMetalProbe {
    static func install() {}
}
#endif
