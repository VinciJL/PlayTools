import Foundation
import Metal
import OSLog
import QuartzCore

/// Renders the window's UIKit layer tree into an offscreen texture with
/// CARenderer so screenshots can composite UIKit content (web views, native
/// overlays) into the game's Metal frame. The UI texture is rendered at the
/// live window size and stretched over the captured frame by the composite
/// pass, so the resulting image matches what the display shows with one
/// unified geometry.
final class UICaptureCompositor {
    static let shared = UICaptureCompositor()

    private let logger = Logger(subsystem: "PlayTools", category: "UICapture")

    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var uiTexture: MTLTexture?
    private var textureSize = CGSize.zero
    private var renderer: CARenderer?
    private var rendererQueue: MTLCommandQueue?
    private var pendingUpdate = false
    private var lastUpdate = Date.distantPast

    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?

    private init() {}

    /// Points the compositor at the capture pipeline's device and command
    /// queue. Idempotent; switching queues rebuilds the renderer so its GPU
    /// work stays ordered with the composite pass.
    func configure(device: MTLDevice, queue: MTLCommandQueue) {
        guard self.device !== device || self.queue !== queue else { return }
        self.device = device
        self.queue = queue
        renderer = nil
        uiTexture = nil
        textureSize = .zero
        buildPipelineIfNeeded()
    }

    /// Called from the present hook (any thread); renders the UI texture on
    /// the main thread, throttled and non-reentrant.
    func updateUI() {
        guard !pendingUpdate else { return }
        guard Date().timeIntervalSince(lastUpdate) >= 0.1 else { return }
        pendingUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingUpdate = false
            self.renderUI()
        }
    }

    /// Encodes a pass drawing the latest UI texture over the captured game
    /// frame (which must be renderable). No-op when no UI frame is ready.
    func composite(over texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let uiTexture = uiTexture,
              let pipeline = pipeline,
              let sampler = sampler else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(uiTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    // MARK: - Private

    private func renderUI() {
        guard let device = device, let queue = queue else { return }
        guard let window = PlayScreen.shared.keyWindow else { return }
        let size = window.bounds.size
        guard size.width >= 1, size.height >= 1 else { return }
        lastUpdate = Date()

        ensureUITexture(device: device, size: size)
        guard let texture = uiTexture else { return }
        ensureRenderer(queue: queue, texture: texture, size: size)
        guard let renderer = renderer else { return }

        // Clear previous frame, then let CARenderer draw the layer tree. The
        // first cycles after (re)creation are no-ops by design; continuously
        // driven updates keep the texture current for on-demand captures.
        if let commandBuffer = queue.makeCommandBuffer() {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            commandBuffer.commit()
        }
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
    }

    private func ensureUITexture(device: MTLDevice, size: CGSize) {
        guard uiTexture == nil || textureSize != size else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(size.width.rounded(.up)),
            height: Int(size.height.rounded(.up)),
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        uiTexture = device.makeTexture(descriptor: descriptor)
        textureSize = size
        renderer = nil
    }

    private func ensureRenderer(queue: MTLCommandQueue, texture: MTLTexture, size: CGSize) {
        guard renderer == nil || rendererQueue !== queue else { return }
        let options: [AnyHashable: Any] = [
            kCARendererMetalCommandQueue: queue,
            kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        ]
        let newRenderer = CARenderer(mtlTexture: texture, options: options)
        newRenderer.layer = PlayScreen.shared.keyWindow?.layer
        newRenderer.bounds = CGRect(origin: .zero, size: size)
        renderer = newRenderer
        rendererQueue = queue
    }

    private func buildPipelineIfNeeded() {
        guard pipeline == nil, let device = device else { return }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vs")
            descriptor.fragmentFunction = library.makeFunction(name: "fs")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            // CARenderer output is premultiplied alpha
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        } catch {
            logger.error("Failed to build UI composite pipeline: \(error.localizedDescription)")
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut {
        float4 position [[position]];
        float2 uv;
    };
    vertex VOut vs(uint vid [[vertex_id]]) {
        float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0),
                                float2(-1.0, 1.0), float2(1.0, 1.0) };
        // The CARenderer output stores the layer tree's bottom (CA y = 0) in
        // texture row 0, i.e. flipped relative to the screen; invert V while
        // sampling so UIKit content ends up upright over the game frame.
        float2 uvs[4] = { float2(0.0, 0.0), float2(1.0, 0.0),
                          float2(0.0, 1.0), float2(1.0, 1.0) };
        VOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }
    fragment float4 fs(VOut in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler samp [[sampler(0)]]) {
        return tex.sample(samp, in.uv);
    }
    """
}
