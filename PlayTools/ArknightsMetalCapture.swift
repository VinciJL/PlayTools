import Foundation

struct ArknightsMetalFrame {
    let frameID: UInt64
    let timestamp: UInt64
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: UInt16
    let orientation: UInt16
    let rotation: UInt16
    let data: Data
}

enum ArknightsMetalCaptureResult {
    case ready(ArknightsMetalFrame)
    case noFrame
    case unsupportedFormat
    case temporarilyDisabled
}

#if PLAYTOOLS_METAL_CAPTURE && !PLAYTOOLS_METAL_PROBE
import Darwin
import Metal
import ObjectiveC.runtime
import OSLog
import QuartzCore
import UIKit

private final class ArknightsMetalCaptureSlot {
    enum State {
        case free
        case inFlight
        case reading
    }

    let buffer: MTLBuffer
    let length: Int
    let bytesPerRow: Int
    let width: Int
    let height: Int
    var state = State.free
    var generation: UInt64 = 0
    var frameID: UInt64 = 0

    init(buffer: MTLBuffer, length: Int, bytesPerRow: Int, width: Int, height: Int) {
        self.buffer = buffer
        self.length = length
        self.bytesPerRow = bytesPerRow
        self.width = width
        self.height = height
    }
}

private struct ArknightsMetalSurface {
    let layerID: UInt
    let device: MTLDevice
    let deviceID: UInt
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
    let sampleCount: Int
    let framebufferOnly: Bool
}

private final class ArknightsMetalDrawableRef {
    weak var drawable: CAMetalDrawable?
    init(_ drawable: CAMetalDrawable) {
        self.drawable = drawable
    }
}

private struct ArknightsMetalDrawableTicket {
    let identity: UInt
    let layerID: UInt
    let deviceID: UInt
    let generation: UInt64
    let width: Int
    let height: Int
    let pixelFormat: MTLPixelFormat
    let sampleCount: Int
    let framebufferOnly: Bool
    let drawableRef: ArknightsMetalDrawableRef?
}

private struct ArknightsMetalSetupRequest {
    let surface: ArknightsMetalSurface
    let generation: UInt64
}

final class ArknightsMetalCapture {
    private static let targetBundleIdentifier = "com.hypergryph.arknights"
    private static let nextDrawableSelector = Selector(("nextDrawable"))
    private static let commandBufferSelector = Selector(("commandBuffer"))
    private static let commandBufferWithUnretainedReferencesSelector = Selector(("commandBufferWithUnretainedReferences"))
    private static let commitSelector = Selector(("commit"))
    private static let presentDrawableSelector = Selector(("presentDrawable:"))
    private static let presentDrawableAtTimeSelector = Selector(("presentDrawable:atTime:"))
    private static let presentDrawableAfterMinimumDurationSelector = Selector(("presentDrawable:afterMinimumDuration:"))
    private static let presentDrawableOptionsSelector = Selector(("presentDrawable:options:"))
    private static let drawablePresentSelector = Selector(("present"))
    private static let drawablePresentAtTimeSelector = Selector(("presentAtTime:"))
    private static let drawablePresentAfterMinimumDurationSelector = Selector(("presentAfterMinimumDuration:"))
    private static let expectedPresentEncoding = "v24@0:8@16"
    private static let expectedTimedPresentEncoding = "v32@0:8@16d24"
    private static let expectedPresentOptionsEncoding = "v32@0:8@16@24"
    private static let slotCount = 3
    private static let rowAlignment = 256
    private static let maximumBufferLength = 256 * 1024 * 1024

    private let logger = Logger(subsystem: "com.playcover.PlayTools", category: "metal-capture")
    private let logQueue = DispatchQueue(label: "com.playcover.PlayTools.metal-capture.log")
    private let setupQueue = DispatchQueue(label: "com.playcover.PlayTools.metal-capture.setup", qos: .utility)
    private let readbackQueue = DispatchQueue(label: "com.playcover.PlayTools.metal-capture.readback", qos: .userInitiated)

    private var stateLock = os_unfair_lock_s()
    private var nextHookInstalled = false
    private var commandBufferHookInstalled = false
    private var commitHookInstalled = false
    private var presentHookInstalled = false
    private var drawablePresentHookInstalled = false
    private var drawablePresentHookScheduled = false
    private var presentOptionsHookInstalled = false
    private var presentObserved = false
    private var nextDrawableObserved = false
    private var commandBufferObserved = false
    private var commitObserved = false
    private var disabled = false
    private var backgrounded = false
    private var captureArmed = false
    private var setupScheduled = false
    private var generation: UInt64 = 1
    private var nextFrameID: UInt64 = 0
    private var observedSurface: ArknightsMetalSurface?
    private var slots: [ArknightsMetalCaptureSlot] = []
    private var drawableTickets: [ArknightsMetalDrawableTicket] = []
    private var readyFrame: ArknightsMetalFrame?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var commitCount: UInt64 = 0
    private var nextCount: UInt64 = 0
    private var presentCount: UInt64 = 0
    private var tickerScheduled = false

    static let shared = ArknightsMetalCapture()

    static func install() {
        shared.installIfNeeded()
    }

    static func requestFrame() -> ArknightsMetalCaptureResult {
        shared.request()
    }

    private func installIfNeeded() {
        log("event=install-enter")
        guard Bundle.main.bundleIdentifier == Self.targetBundleIdentifier else { return }

        installLifecycleObservers()

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let concreteClass = object_getClass(commandBuffer),
              let method = class_getInstanceMethod(concreteClass, Self.presentDrawableSelector),
              let types = method_getTypeEncoding(method) else {
            disable(reason: "missing-command-buffer")
            return
        }

        let concreteEncoding = String(cString: types)
        let protocolEncoding = Self.protocolMethodEncoding(
            protocolName: "MTLCommandBuffer",
            selector: Self.presentDrawableSelector
        )
        guard concreteEncoding == Self.expectedPresentEncoding,
              protocolEncoding == Self.expectedPresentEncoding else {
            log("event=abi result=unsupported concreteClass=\(String(cString: class_getName(concreteClass))) concreteEncoding=\(concreteEncoding) protocolEncoding=\(protocolEncoding)")
            disable(reason: "present-encoding")
            return
        }

        let callback: PTMetalPresentHookCallback = { [weak self] commandBuffer, drawable in
            self?.observePresent(commandBuffer: commandBuffer, drawable: drawable)
        }
        guard PTInstallMetalPresentHook(concreteClass, callback) else {
            disable(reason: "present-hook-install")
            return
        }

        var timedHooks: [String] = []
        let timedSelectors: [(Selector, String)] = [
            (Self.presentDrawableAtTimeSelector, "at-time"),
            (Self.presentDrawableAfterMinimumDurationSelector, "after-minimum-duration")
        ]
        for (selector, name) in timedSelectors {
            guard let timedMethod = class_getInstanceMethod(concreteClass, selector),
                  let timedTypes = method_getTypeEncoding(timedMethod) else {
                log("event=abi variant=\(name) result=missing concreteClass=\(String(cString: class_getName(concreteClass)))")
                continue
            }
            let concreteTimedEncoding = String(cString: timedTypes)
            let protocolTimedEncoding = Self.protocolMethodEncoding(
                protocolName: "MTLCommandBuffer",
                selector: selector
            )
            guard concreteTimedEncoding == Self.expectedTimedPresentEncoding,
                  protocolTimedEncoding == Self.expectedTimedPresentEncoding else {
                log("event=abi variant=\(name) result=unsupported concreteEncoding=\(concreteTimedEncoding) protocolEncoding=\(protocolTimedEncoding)")
                continue
            }
            guard PTInstallMetalTimedPresentHook(concreteClass, selector, callback) else {
                log("event=abi variant=\(name) result=install-failed")
                continue
            }
            timedHooks.append(name)
        }

        presentHookInstalled = true
        log("event=abi result=installed concreteClass=\(String(cString: class_getName(concreteClass))) concreteEncoding=\(concreteEncoding) protocolEncoding=\(protocolEncoding) timedHooks=\(timedHooks.joined(separator: ","))")
        logCommandBufferMethods(concreteClass)
        installCommitHook(commandBufferClass: concreteClass)
        installPresentOptionsHook(commandBufferClass: concreteClass)
        installCommandBufferHook(commandQueue: commandQueue)
        installNextDrawableHook(retriesRemaining: 3)
        scheduleTicker()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("PT_M1_TEST_ARM")
        if FileManager.default.fileExists(atPath: marker.path) {
            scheduleTestArm(after: 15)
            scheduleTestArm(after: 20)
            scheduleTestArm(after: 30)
            scheduleTestArm(after: 40)
            scheduleTestArm(after: 55)
            scheduleTestArm(after: 65)
        }
    }

    private func scheduleTestArm(after seconds: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
            guard let self else { return }
            let result = self.request()
            switch result {
            case .ready(let frame):
                let data = frame.data
                let (contentRegions, overallRatio) = Self.frameContentStatistics(
                    data: data,
                    width: frame.width,
                    height: frame.height,
                    bytesPerRow: frame.bytesPerRow
                )
                self.log("event=test-arm result=ready frameID=\(frame.frameID) width=\(frame.width) height=\(frame.height) bytesPerRow=\(frame.bytesPerRow) dataLength=\(frame.data.count) content=\(overallRatio > 0.01 ? "non-uniform" : "uniform") contentRegions=\(contentRegions)/16 overallRatio=\(String(format: "%.3f", overallRatio))")
            case .noFrame:
                self.log("event=test-arm result=no-frame")
            case .unsupportedFormat:
                self.log("event=test-arm result=unsupported-format")
            case .temporarilyDisabled:
                self.log("event=test-arm result=temporarily-disabled")
            }
        }
    }

    private static func frameContentStatistics(data: Data,
                                               width: Int,
                                               height: Int,
                                               bytesPerRow: Int) -> (contentRegions: Int, overallRatio: Double) {
        guard data.count > 0, width > 0, height > 0 else { return (0, 0) }
        let gridRows = 4
        let gridCols = 4
        var nonZeroTotal = 0
        var pixelTotal = 0
        var contentRegions = 0
        for regionRow in 0..<gridRows {
            for regionCol in 0..<gridCols {
                let startRow = regionRow * height / gridRows
                let endRow = (regionRow + 1) * height / gridRows
                let startCol = regionCol * width / gridCols
                let endCol = (regionCol + 1) * width / gridCols
                var regionNonZero = 0
                var regionPixels = 0
                for row in startRow..<endRow {
                    let rowBase = row * bytesPerRow
                    if rowBase >= data.count { break }
                    var col = startCol
                    while col < endCol {
                        let offset = rowBase + col * 4
                        if offset < data.count, data[data.startIndex + offset] != 0 {
                            regionNonZero += 1
                        }
                        regionPixels += 1
                        col += 4
                    }
                }
                nonZeroTotal += regionNonZero
                pixelTotal += regionPixels
                if regionPixels > 0, Double(regionNonZero) / Double(regionPixels) > 0.3 {
                    contentRegions += 1
                }
            }
        }
        let overallRatio = pixelTotal > 0 ? Double(nonZeroTotal) / Double(pixelTotal) : 0
        return (contentRegions, overallRatio)
    }

    private func scheduleTicker() {
        logQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            var commits = 0
            var nexts = 0
            var presents = 0
            if os_unfair_lock_trylock(&self.stateLock) {
                commits = Int(truncatingIfNeeded: self.commitCount)
                nexts = Int(truncatingIfNeeded: self.nextCount)
                presents = Int(truncatingIfNeeded: self.presentCount)
                os_unfair_lock_unlock(&self.stateLock)
            }
            self.log("event=tick commits=\(commits) nexts=\(nexts) presents=\(presents)")
            self.scheduleTicker()
        }
    }

    private func installDrawablePresentHooks(on drawableClass: AnyClass?) {
        guard !drawablePresentHookInstalled,
              let drawableClass else { return }

        let callback: PTMetalPresentHookCallback = { [weak self] commandBuffer, drawable in
            self?.observePresent(commandBuffer: commandBuffer, drawable: drawable)
        }
        guard PTInstallMetalDrawablePresentHook(drawableClass, callback) else {
            log("event=drawable-present-hook result=install-failed concreteClass=\(String(cString: class_getName(drawableClass)))")
            return
        }

        var timedVariants: [String] = []
        let timedSelectors: [(Selector, String)] = [
            (Self.drawablePresentAtTimeSelector, "at-time"),
            (Self.drawablePresentAfterMinimumDurationSelector, "after-minimum-duration")
        ]
        for (selector, name) in timedSelectors {
            if PTInstallMetalTimedDrawablePresentHook(drawableClass, selector, callback) {
                timedVariants.append(name)
            }
        }

        drawablePresentHookInstalled = true
        log("event=drawable-present-hook result=installed concreteClass=\(String(cString: class_getName(drawableClass))) timedVariants=\(timedVariants.joined(separator: ","))")
    }

    private func installPresentOptionsHook(commandBufferClass: AnyClass) {
        guard !presentOptionsHookInstalled else { return }

        let callback: PTMetalPresentHookCallback = { [weak self] commandBuffer, drawable in
            self?.observePresent(commandBuffer: commandBuffer, drawable: drawable)
        }
        guard PTInstallMetalPresentOptionsHook(commandBufferClass, callback) else {
            log("event=present-options-hook result=missing")
            return
        }
        presentOptionsHookInstalled = true
        log("event=present-options-hook result=installed concreteClass=\(String(cString: class_getName(commandBufferClass)))")
    }

    private func logCommandBufferMethods(_ concreteClass: AnyClass) {
        var methods: [String] = []
        var currentClass: AnyClass? = concreteClass
        while let type = currentClass {
            var count: UInt32 = 0
            if let methodList = class_copyMethodList(type, &count) {
                for index in 0..<Int(count) {
                    let method = methodList[index]
                    let selector = method_getName(method)
                    let name = NSStringFromSelector(selector)
                    if name.contains("present") || name == "commit" || name == "enqueue" {
                        let types = method_getTypeEncoding(method).map(String.init(cString:)) ?? "missing"
                        let owner = String(cString: class_getName(type))
                        methods.append("\(owner):\(name):\(types)")
                    }
                }
                free(methodList)
            }
            currentClass = class_getSuperclass(type)
        }
        log("event=command-buffer-methods concreteClass=\(String(cString: class_getName(concreteClass))) methods=\(methods.joined(separator: ","))")
    }

    private func installCommitHook(commandBufferClass: AnyClass) {
        guard !commitHookInstalled,
              let inheritedMethod = class_getInstanceMethod(commandBufferClass, Self.commitSelector),
              let types = method_getTypeEncoding(inheritedMethod),
              String(cString: types) == "v16@0:8" else {
            log("event=commit-hook result=missing")
            return
        }

        let originalImplementation = method_getImplementation(inheritedMethod)
        if !Self.classDefinesSelector(commandBufferClass, Self.commitSelector),
           !class_addMethod(commandBufferClass, Self.commitSelector, originalImplementation, types) {
            log("event=commit-hook result=add-method-failed")
            return
        }
        guard let method = class_getInstanceMethod(commandBufferClass, Self.commitSelector) else {
            log("event=commit-hook result=missing-method")
            return
        }

        let original: @convention(c) (AnyObject, Selector) -> Void = unsafeBitCast(
            originalImplementation,
            to: (@convention(c) (AnyObject, Selector) -> Void).self
        )
        let selector = Self.commitSelector
        let replacement: @convention(block) (AnyObject) -> Void = { [weak self] commandBuffer in
            self?.observeCommit(commandBuffer)
            original(commandBuffer, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        commitHookInstalled = true
        log("event=commit-hook result=installed concreteClass=\(String(cString: class_getName(commandBufferClass)))")
    }

    private func observeCommit(_ commandBuffer: AnyObject) {
        var shouldLog = false
        guard os_unfair_lock_trylock(&stateLock) else { return }
        commitCount &+= 1
        if !commitObserved {
            commitObserved = true
            shouldLog = true
        }
        os_unfair_lock_unlock(&stateLock)

        if shouldLog {
            let concreteClass = String(cString: class_getName(object_getClass(commandBuffer)))
            let status = (commandBuffer as? MTLCommandBuffer).map { String(describing: $0.status) } ?? "not-command-buffer"
            log("event=commit-enter concreteClass=\(concreteClass) status=\(status) commandBufferID=\(objectID(commandBuffer))")
        }

        guard let commandBuffer = commandBuffer as? MTLCommandBuffer else { return }
        encodeCaptureIfArmed(commandBuffer: commandBuffer)
    }

    private func encodeCaptureIfArmed(commandBuffer: MTLCommandBuffer) {
        var ticket: ArknightsMetalDrawableTicket?
        guard os_unfair_lock_trylock(&stateLock) else { return }
        if captureArmed, let newest = drawableTickets.last {
            ticket = newest
        }
        os_unfair_lock_unlock(&stateLock)
        guard let ticket,
              let drawable = ticket.drawableRef?.drawable else { return }
        encodeCapture(commandBuffer: commandBuffer, drawable: drawable, ticket: ticket)
    }

    private func installCommandBufferHook(commandQueue: MTLCommandQueue) {
        guard let queueClass = object_getClass(commandQueue) else {
            log("event=command-buffer-hook result=missing-queue-class")
            return
        }

        let selectors = [
            Self.commandBufferSelector,
            Self.commandBufferWithUnretainedReferencesSelector
        ]
        var installed = 0
        for selector in selectors {
            guard let inheritedMethod = class_getInstanceMethod(queueClass, selector),
                  let types = method_getTypeEncoding(inheritedMethod),
                  String(cString: types) == "@16@0:8" else {
                continue
            }

            let originalImplementation = method_getImplementation(inheritedMethod)
            if !Self.classDefinesSelector(queueClass, selector) {
                guard class_addMethod(queueClass, selector, originalImplementation, types) else {
                    continue
                }
            }
            guard let method = class_getInstanceMethod(queueClass, selector) else {
                continue
            }

            let original: @convention(c) (AnyObject, Selector) -> AnyObject? = unsafeBitCast(
                originalImplementation,
                to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self
            )
            let queueSelector = selector
            let replacement: @convention(block) (AnyObject) -> AnyObject? = { [weak self] queue in
                let commandBuffer = original(queue, queueSelector)
                self?.observeCommandBuffer(commandBuffer, selector: queueSelector)
                return commandBuffer
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
            installed += 1
        }

        commandBufferHookInstalled = installed > 0
        let queueName = String(cString: class_getName(queueClass))
        let result = installed > 0 ? "installed" : "missing"
        log("event=command-buffer-hook result=\(result) concreteClass=\(queueName) count=\(installed)")
    }

    private func observeCommandBuffer(_ commandBuffer: AnyObject?, selector: Selector) {
        guard let commandBuffer else { return }
        var shouldLog = false
        guard os_unfair_lock_trylock(&stateLock) else { return }
        if !commandBufferObserved {
            commandBufferObserved = true
            shouldLog = true
        }
        os_unfair_lock_unlock(&stateLock)

        if shouldLog {
            let commandBufferClass = String(cString: class_getName(object_getClass(commandBuffer)))
            log("event=command-buffer result=observed selector=\(NSStringFromSelector(selector)) concreteClass=\(commandBufferClass) objectID=\(objectID(commandBuffer))")
        }
    }

    private func installNextDrawableHook(retriesRemaining: Int) {
        guard !nextHookInstalled else { return }

        guard let method = class_getInstanceMethod(CAMetalLayer.self, Self.nextDrawableSelector) else {
            if retriesRemaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.installNextDrawableHook(retriesRemaining: retriesRemaining - 1)
                }
            } else {
                disable(reason: "missing-next-drawable")
            }
            return
        }

        let originalImplementation = method_getImplementation(method)
        let original: @convention(c) (CAMetalLayer, Selector) -> CAMetalDrawable? = unsafeBitCast(
            originalImplementation,
            to: (@convention(c) (CAMetalLayer, Selector) -> CAMetalDrawable?).self
        )
        let selector = Self.nextDrawableSelector
        let replacement: @convention(block) (CAMetalLayer) -> CAMetalDrawable? = { [weak self] layer in
            let drawable = original(layer, selector)
            self?.observeNextDrawable(layer: layer, drawable: drawable)
            return drawable
        }

        method_setImplementation(method, imp_implementationWithBlock(replacement))
        nextHookInstalled = true
        log("event=next-hook result=installed")
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
                    self?.setBackgrounded(true)
                }
            )
            self.lifecycleObservers.append(
                center.addObserver(
                    forName: UIApplication.willEnterForegroundNotification,
                    object: nil,
                    queue: nil
                ) { [weak self] _ in
                    self?.setBackgrounded(false)
                }
            )
        }
    }

    private func observeNextDrawable(layer: CAMetalLayer, drawable: CAMetalDrawable?) {
        guard let drawable else { return }
        let texture = drawable.texture
        let layerID = objectID(layer)
        let device = texture.device
        let surface = ArknightsMetalSurface(
            layerID: layerID,
            device: device,
            deviceID: objectID(device),
            width: texture.width,
            height: texture.height,
            pixelFormat: texture.pixelFormat,
            sampleCount: texture.sampleCount,
            framebufferOnly: layer.framebufferOnly
        )
        let ticket = ArknightsMetalDrawableTicket(
            identity: objectID(drawable),
            layerID: layerID,
            deviceID: surface.deviceID,
            generation: 0,
            width: surface.width,
            height: surface.height,
            pixelFormat: surface.pixelFormat,
            sampleCount: surface.sampleCount,
            framebufferOnly: surface.framebufferOnly,
            drawableRef: nil
        )

        var setupRequest: ArknightsMetalSetupRequest?
        var shouldLog = false
        guard os_unfair_lock_trylock(&stateLock) else { return }
        nextCount &+= 1

        let surfaceChanged: Bool
        if let observedSurface {
            surfaceChanged = !sameSurface(observedSurface, surface)
        } else {
            surfaceChanged = true
        }

        if surfaceChanged {
            generation &+= 1
            readyFrame = nil
            slots.removeAll(keepingCapacity: true)
            drawableTickets.removeAll(keepingCapacity: true)
            observedSurface = surface
        }

        let currentTicket = ArknightsMetalDrawableTicket(
            identity: ticket.identity,
            layerID: ticket.layerID,
            deviceID: ticket.deviceID,
            generation: generation,
            width: ticket.width,
            height: ticket.height,
            pixelFormat: ticket.pixelFormat,
            sampleCount: ticket.sampleCount,
            framebufferOnly: ticket.framebufferOnly,
            drawableRef: ArknightsMetalDrawableRef(drawable)
        )
        if drawableTickets.count == 8 {
            drawableTickets.removeFirst()
        }
        drawableTickets.append(currentTicket)
        if !nextDrawableObserved {
            nextDrawableObserved = true
            shouldLog = true
        }

        if captureArmed,
           !backgrounded,
           !disabled,
           slots.isEmpty,
           !setupScheduled,
           isSupported(surface) {
            setupScheduled = true
            setupRequest = ArknightsMetalSetupRequest(surface: surface, generation: generation)
        }

        var scheduleDrawableHooks = false
        if !drawablePresentHookInstalled, !drawablePresentHookScheduled {
            drawablePresentHookScheduled = true
            scheduleDrawableHooks = true
        }
        os_unfair_lock_unlock(&stateLock)

        if scheduleDrawableHooks {
            let drawableObject = drawable as AnyObject
            let drawableClass = object_getClass(drawableObject)
            DispatchQueue.main.async { [weak self] in
                self?.installDrawablePresentHooks(on: drawableClass)
            }
        }

        if shouldLog {
            log("event=next result=observed layerID=\(layerID) drawableID=\(currentTicket.identity) deviceID=\(currentTicket.deviceID) width=\(currentTicket.width) height=\(currentTicket.height) pixelFormat=\(currentTicket.pixelFormat.rawValue) sampleCount=\(currentTicket.sampleCount) framebufferOnly=\(currentTicket.framebufferOnly)")
        }

        if let setupRequest {
            scheduleSetup(setupRequest)
        }
    }

    private func observePresent(commandBuffer: Any, drawable: Any) {
        guard let drawable = drawable as? CAMetalDrawable else {
            return
        }

        let drawableIdentity = objectID(drawable)
        var ticket: ArknightsMetalDrawableTicket?
        var shouldLog = false
        guard os_unfair_lock_trylock(&stateLock) else { return }
        presentCount &+= 1
        if let index = drawableTickets.firstIndex(where: { $0.identity == drawableIdentity }) {
            ticket = drawableTickets.remove(at: index)
        }
        if !presentObserved {
            presentObserved = true
            shouldLog = true
        }
        os_unfair_lock_unlock(&stateLock)

        if shouldLog {
            let concreteClass = String(describing: type(of: drawable))
            log("event=present result=observed concreteClass=\(concreteClass) drawableID=\(drawableIdentity) matchedTicket=\(ticket != nil)")
        }
    }

    private func encodeCapture(commandBuffer: MTLCommandBuffer,
                               drawable: CAMetalDrawable,
                               ticket: ArknightsMetalDrawableTicket) {
        let texture = drawable.texture
        guard commandBuffer.status == .notEnqueued,
              ticket.generation == currentGeneration(),
              ticket.deviceID == objectID(texture.device),
              ticket.width == texture.width,
              ticket.height == texture.height,
              ticket.pixelFormat == texture.pixelFormat,
              ticket.sampleCount == texture.sampleCount,
              !ticket.framebufferOnly,
              texture.pixelFormat == .bgra8Unorm,
              texture.sampleCount == 1,
              texture.width > 0,
              texture.height > 0 else {
            return
        }

        var slot: ArknightsMetalCaptureSlot?
        var frameID: UInt64 = 0
        var frameTimestamp: UInt64 = 0
        guard os_unfair_lock_trylock(&stateLock) else { return }
        guard captureArmed,
              !backgrounded,
              !disabled,
              ticket.generation == generation,
              let availableSlot = slots.first(where: { $0.state == .free }),
              availableSlot.width == texture.width,
              availableSlot.height == texture.height else {
            os_unfair_lock_unlock(&stateLock)
            return
        }

        nextFrameID &+= 1
        frameID = nextFrameID
        frameTimestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        availableSlot.state = .inFlight
        availableSlot.generation = generation
        availableSlot.frameID = frameID
        captureArmed = false
        slot = availableSlot
        os_unfair_lock_unlock(&stateLock)

        guard let slot else { return }
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            cancelCapture(slot: slot, generation: ticket.generation)
            return
        }

        encoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: slot.buffer,
            destinationOffset: 0,
            destinationBytesPerRow: slot.bytesPerRow,
            destinationBytesPerImage: slot.bytesPerRow * slot.height
        )
        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            self?.completeCapture(
                slot: slot,
                generation: ticket.generation,
                frameID: frameID,
                timestamp: frameTimestamp,
                commandBuffer: commandBuffer
            )
        }
    }

    private func completeCapture(slot: ArknightsMetalCaptureSlot,
                                 generation: UInt64,
                                 frameID: UInt64,
                                 timestamp: UInt64,
                                 commandBuffer: MTLCommandBuffer) {
        guard commandBuffer.status == .completed, commandBuffer.error == nil else {
            log("event=copy result=failed frameID=\(frameID) status=\(commandBuffer.status.rawValue) error=\(commandBuffer.error?.localizedDescription ?? "nil")")
            cancelCapture(slot: slot, generation: generation)
            return
        }

        guard os_unfair_lock_trylock(&stateLock) else {
            cancelCapture(slot: slot, generation: generation)
            return
        }
        guard slot.state == .inFlight,
              slot.generation == generation,
              self.generation == generation,
              !backgrounded else {
            slot.state = .free
            os_unfair_lock_unlock(&stateLock)
            return
        }
        slot.state = .reading
        os_unfair_lock_unlock(&stateLock)
        log("event=copy result=completed frameID=\(frameID) width=\(slot.width) height=\(slot.height) bytesPerRow=\(slot.bytesPerRow) length=\(slot.length)")

        readbackQueue.async { [weak self] in
            let data = Data(bytes: slot.buffer.contents(), count: slot.length)
            self?.publish(
                data: data,
                slot: slot,
                generation: generation,
                frameID: frameID,
                timestamp: timestamp
            )
        }
    }

    private func publish(data: Data,
                         slot: ArknightsMetalCaptureSlot,
                         generation: UInt64,
                         frameID: UInt64,
                         timestamp: UInt64) {
        guard os_unfair_lock_trylock(&stateLock) else {
            returnCaptureSlot(slot)
            return
        }
        guard slot.state == .reading,
              self.generation == generation,
              !backgrounded else {
            slot.state = .free
            os_unfair_lock_unlock(&stateLock)
            return
        }

        slot.state = .free
        let frame = ArknightsMetalFrame(
            frameID: frameID,
            timestamp: timestamp,
            width: slot.width,
            height: slot.height,
            bytesPerRow: slot.bytesPerRow,
            pixelFormat: 1,
            // 1 = up: buffer row 0 is the top of the presented image
            // (Metal/CAMetalLayer drawable textures are non-flipped)
            orientation: 1,
            rotation: 0,
            data: data
        )
        if readyFrame == nil || readyFrame!.frameID < frameID {
            readyFrame = frame
        }
        os_unfair_lock_unlock(&stateLock)
        log("event=frame result=published frameID=\(frameID) width=\(frame.width) height=\(frame.height) bytesPerRow=\(frame.bytesPerRow) dataLength=\(frame.data.count)")
    }

    private func cancelCapture(slot: ArknightsMetalCaptureSlot, generation: UInt64) {
        guard os_unfair_lock_trylock(&stateLock) else { return }
        slot.state = .free
        if self.generation == generation, !backgrounded, !disabled {
            captureArmed = true
        }
        os_unfair_lock_unlock(&stateLock)
    }

    private func returnCaptureSlot(_ slot: ArknightsMetalCaptureSlot) {
        guard os_unfair_lock_trylock(&stateLock) else { return }
        slot.state = .free
        os_unfair_lock_unlock(&stateLock)
    }

    private func request() -> ArknightsMetalCaptureResult {
        var setupRequest: ArknightsMetalSetupRequest?
        var result: ArknightsMetalCaptureResult = .noFrame
        guard os_unfair_lock_trylock(&stateLock) else { return .noFrame }

        if let readyFrame {
            self.readyFrame = nil
            result = .ready(readyFrame)
        } else if backgrounded || disabled || !presentHookInstalled || !nextHookInstalled {
            result = .temporarilyDisabled
        } else if let observedSurface, !isSupported(observedSurface) {
            captureArmed = false
            result = .unsupportedFormat
        } else {
            captureArmed = true
            if let observedSurface,
               slots.isEmpty,
               !setupScheduled {
                setupScheduled = true
                setupRequest = ArknightsMetalSetupRequest(surface: observedSurface, generation: generation)
            }
        }
        os_unfair_lock_unlock(&stateLock)

        if let setupRequest {
            scheduleSetup(setupRequest)
        }
        return result
    }

    private func scheduleSetup(_ request: ArknightsMetalSetupRequest) {
        setupQueue.async { [weak self] in
            self?.buildPool(for: request)
        }
    }

    private func buildPool(for request: ArknightsMetalSetupRequest) {
        let width = request.surface.width
        let height = request.surface.height
        let sourceRowBytesResult = width.multipliedReportingOverflow(by: 4)
        guard !sourceRowBytesResult.overflow,
              let alignedRowBytes = Self.aligned(sourceRowBytesResult.partialValue) else {
            clearSetupSchedule(for: request.generation)
            log("event=setup result=unsupported width=\(width) height=\(height)")
            return
        }

        let lengthResult = alignedRowBytes.multipliedReportingOverflow(by: height)
        guard !lengthResult.overflow,
              lengthResult.partialValue <= Self.maximumBufferLength else {
            clearSetupSchedule(for: request.generation)
            log("event=setup result=unsupported width=\(width) height=\(height)")
            return
        }

        let length = lengthResult.partialValue
        var newSlots: [ArknightsMetalCaptureSlot] = []
        newSlots.reserveCapacity(Self.slotCount)
        for _ in 0..<Self.slotCount {
            guard let buffer = request.surface.device.makeBuffer(
                length: length,
                options: .storageModeShared
            ) else {
                clearSetupSchedule(for: request.generation)
                log("event=setup result=buffer-failed width=\(width) height=\(height)")
                return
            }
            newSlots.append(
                ArknightsMetalCaptureSlot(
                    buffer: buffer,
                    length: length,
                    bytesPerRow: alignedRowBytes,
                    width: width,
                    height: height
                )
            )
        }

        guard os_unfair_lock_trylock(&stateLock) else { return }
        guard generation == request.generation,
              let observedSurface,
              sameSurface(observedSurface, request.surface) else {
            os_unfair_lock_unlock(&stateLock)
            return
        }
        slots = newSlots
        setupScheduled = false
        os_unfair_lock_unlock(&stateLock)
        log("event=setup result=ready width=\(width) height=\(height) bytesPerRow=\(alignedRowBytes) slots=\(Self.slotCount)")
    }

    private func clearSetupSchedule(for generation: UInt64) {
        guard os_unfair_lock_trylock(&stateLock) else { return }
        if self.generation == generation {
            setupScheduled = false
        }
        os_unfair_lock_unlock(&stateLock)
    }

    private func setBackgrounded(_ value: Bool) {
        guard os_unfair_lock_trylock(&stateLock) else { return }
        backgrounded = value
        generation &+= 1
        captureArmed = false
        readyFrame = nil
        slots.removeAll(keepingCapacity: true)
        drawableTickets.removeAll(keepingCapacity: true)
        observedSurface = nil
        os_unfair_lock_unlock(&stateLock)
        log("event=lifecycle state=\(value ? "background" : "foreground")")
    }

    private func disable(reason: String) {
        guard os_unfair_lock_trylock(&stateLock) else { return }
        disabled = true
        captureArmed = false
        os_unfair_lock_unlock(&stateLock)
        log("event=disabled reason=\(reason)")
    }

    private func currentGeneration() -> UInt64 {
        guard os_unfair_lock_trylock(&stateLock) else { return 0 }
        let value = generation
        os_unfair_lock_unlock(&stateLock)
        return value
    }

    private func sameSurface(_ lhs: ArknightsMetalSurface, _ rhs: ArknightsMetalSurface) -> Bool {
        lhs.layerID == rhs.layerID &&
            lhs.deviceID == rhs.deviceID &&
            lhs.width == rhs.width &&
            lhs.height == rhs.height &&
            lhs.pixelFormat == rhs.pixelFormat &&
            lhs.sampleCount == rhs.sampleCount &&
            lhs.framebufferOnly == rhs.framebufferOnly
    }

    private func isSupported(_ surface: ArknightsMetalSurface) -> Bool {
        surface.width > 0 &&
            surface.height > 0 &&
            surface.pixelFormat == .bgra8Unorm &&
            surface.sampleCount == 1 &&
            !surface.framebufferOnly
    }

    private static func isSupported(_ surface: ArknightsMetalSurface) -> Bool {
        surface.width > 0 &&
            surface.height > 0 &&
            surface.pixelFormat == .bgra8Unorm &&
            surface.sampleCount == 1 &&
            !surface.framebufferOnly
    }

    private static func aligned(_ value: Int) -> Int? {
        guard value > 0,
              value <= Int.max - (rowAlignment - 1) else { return nil }
        return (value + rowAlignment - 1) / rowAlignment * rowAlignment
    }

    private static func classDefinesSelector(_ type: AnyClass, _ selector: Selector) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(type, &count) else { return false }
        defer { free(methods) }
        for index in 0..<Int(count) {
            if method_getName(methods[index]) == selector {
                return true
            }
        }
        return false
    }

    private static func protocolMethodEncoding(protocolName: String, selector: Selector) -> String {
        let protocolObject = protocolName.withCString { objc_getProtocol($0) }
        guard let protocolObject else { return "missing-protocol" }
        let description = protocol_getMethodDescription(protocolObject, selector, true, true)
        guard let types = description.types else { return "missing-method" }
        return String(cString: types)
    }

    private func objectID(_ object: AnyObject) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
    }

    private func log(_ message: String) {
        logQueue.async { [logger] in
            logger.info("\(message, privacy: .public)")
        }
    }
}
#else
final class ArknightsMetalCapture {
    static func install() {}

    static func requestFrame() -> ArknightsMetalCaptureResult {
        .temporarilyDisabled
    }
}
#endif
