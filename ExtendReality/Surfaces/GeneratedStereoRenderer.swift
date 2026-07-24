@preconcurrency import AVFoundation
@preconcurrency import MetalKit
import SwiftUI

struct GeneratedStereoFullscreenView: View {
    let session: MediaSession
    let viewportSize: CGSize
    @State private var displayValidationTask: Task<Void, Never>?

    private var isFullSideBySide: Bool {
        StereoDisplayGeometry.isFullSideBySide(viewportSize)
    }

    var body: some View {
        GeneratedStereoRendererView(session: session)
            .background(Color.black)
            .overlay {
                if !isFullSideBySide {
                    HStack(spacing: 0) {
                        displayModePrompt
                        displayModePrompt
                    }
                }
            }
            .onAppear { validateDisplayMode() }
            .onChange(of: viewportSize) { _, _ in validateDisplayMode() }
            .onDisappear {
                displayValidationTask?.cancel()
                displayValidationTask = nil
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("AI-generated side-by-side 3D video")
    }

    private var displayModePrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "view.3d")
                .font(.system(size: 36, weight: .medium))
            Text("Enable Full SBS on the XREAL glasses")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Waiting for a 3840×1080 display…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.64))
    }

    private func validateDisplayMode() {
        displayValidationTask?.cancel()
        if isFullSideBySide {
            session.reportFullSideBySideDisplayReady()
            return
        }
        session.reportWaitingForFullSideBySideDisplay()
        displayValidationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  !StereoDisplayGeometry.isFullSideBySide(viewportSize) else { return }
            session.reportFullSideBySideDisplayUnavailable()
        }
    }
}

struct GeneratedStereoRendererView: UIViewRepresentable {
    let session: MediaSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.session = session
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var session: MediaSession
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var textureCache: CVMetalTextureCache?
        private var sourceTextureReference: CVMetalTexture?
        private var sourcePixelBuffer: CVPixelBuffer?
        private var sourceTexture: MTLTexture?
        private var depthTexture: MTLTexture?
        private var fallbackDepthTexture: MTLTexture?
        private var depthSequence: UInt64 = 0

        init(session: MediaSession) {
            self.session = session
        }

        func attach(to view: MTKView) {
            guard let device = view.device else {
                session.reportStereoRendererFailure("Metal is unavailable on this device.")
                return
            }
            do {
                commandQueue = device.makeCommandQueue()
                guard let library = device.makeDefaultLibrary(),
                      let vertex = library.makeFunction(name: "generatedStereoVertex"),
                      let fragment = library.makeFunction(name: "generatedStereoFragment") else {
                    throw StereoRendererError.missingShader
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = "Generated Stereo Full SBS"
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
                let status = CVMetalTextureCacheCreate(
                    kCFAllocatorDefault,
                    nil,
                    device,
                    nil,
                    &textureCache
                )
                guard status == kCVReturnSuccess else {
                    throw StereoRendererError.textureCacheCreationFailed
                }
                fallbackDepthTexture = Self.makeFallbackDepthTexture(device: device)
                guard fallbackDepthTexture != nil else {
                    throw StereoRendererError.depthTextureCreationFailed
                }
                view.delegate = self
            } catch {
                session.reportStereoRendererFailure(error.localizedDescription)
            }
        }

        func detach() {
            sourceTextureReference = nil
            sourcePixelBuffer = nil
            sourceTexture = nil
            depthTexture = nil
            fallbackDepthTexture = nil
            if let textureCache {
                CVMetalTextureCacheFlush(textureCache, 0)
            }
            textureCache = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard session.presentationMode == .generatedStereo,
                  let device = view.device,
                  let commandQueue,
                  let pipelineState,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }

            session.evaluateStereoThermalState()
            guard session.presentationMode == .generatedStereo else { return }

            if let frame = session.copyStereoVideoFrame(forHostTime: CACurrentMediaTime()) {
                updateSourceTexture(from: frame.pixelBuffer)
                session.submitDepthFrameIfNeeded(frame.pixelBuffer)
            }
            updateDepthTextureIfNeeded(device: device)

            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            descriptor.colorAttachments[0].storeAction = .store
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }
            encoder.label = "Generated Stereo Gather Warp"
            encoder.setRenderPipelineState(pipelineState)

            if let sourceTexture {
                encoder.setFragmentTexture(sourceTexture, index: 0)
                encoder.setFragmentTexture(depthTexture ?? fallbackDepthTexture, index: 1)
                let targetSize = SIMD2<Float>(
                    Float(view.drawableSize.width / 2),
                    Float(view.drawableSize.height)
                )
                let sourceSize = SIMD2<Float>(
                    Float(sourceTexture.width),
                    Float(sourceTexture.height)
                )
                let frames = StereoDisplayGeometry.eyeFrames(in: view.drawableSize)
                drawEye(
                    frame: frames.left,
                    eyeSign: -1,
                    targetSize: targetSize,
                    sourceSize: sourceSize,
                    encoder: encoder
                )
                drawEye(
                    frame: frames.right,
                    eyeSign: 1,
                    targetSize: targetSize,
                    sourceSize: sourceSize,
                    encoder: encoder
                )
            }

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func drawEye(
            frame: CGRect,
            eyeSign: Float,
            targetSize: SIMD2<Float>,
            sourceSize: SIMD2<Float>,
            encoder: MTLRenderCommandEncoder
        ) {
            var uniforms = GeneratedStereoUniforms(
                sourceSize: sourceSize,
                targetSize: targetSize,
                disparityFraction: Float(session.stereoDisparityPercent / 100),
                eyeSign: eyeSign,
                hasDepth: depthTexture == nil ? 0 : 1,
                rotation: session.videoFrameRotation.rawValue
            )
            encoder.setViewport(
                MTLViewport(
                    originX: frame.minX,
                    originY: frame.minY,
                    width: frame.width,
                    height: frame.height,
                    znear: 0,
                    zfar: 1
                )
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<GeneratedStereoUniforms>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        private func updateSourceTexture(from pixelBuffer: CVPixelBuffer) {
            guard let textureCache else { return }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var textureReference: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &textureReference
            )
            guard status == kCVReturnSuccess,
                  let textureReference,
                  let texture = CVMetalTextureGetTexture(textureReference) else { return }
            sourcePixelBuffer = pixelBuffer
            sourceTextureReference = textureReference
            sourceTexture = texture
        }

        private func updateDepthTextureIfNeeded(device: MTLDevice) {
            guard let frame = session.latestStereoDepthFrame,
                  frame.sequence != depthSequence else { return }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                session.reportStereoRendererFailure("A Metal depth texture could not be created.")
                return
            }
            frame.normalizedFloat16.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: frame.width * MemoryLayout<Float16>.stride
                )
            }
            depthTexture = texture
            depthSequence = frame.sequence
        }

        private static func makeFallbackDepthTexture(device: MTLDevice) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Float,
                width: 1,
                height: 1,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            var middleDepth = Float16(0.5).bitPattern
            texture.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: &middleDepth,
                bytesPerRow: MemoryLayout<UInt16>.stride
            )
            return texture
        }
    }
}

private struct GeneratedStereoUniforms {
    var sourceSize: SIMD2<Float>
    var targetSize: SIMD2<Float>
    var disparityFraction: Float
    var eyeSign: Float
    var hasDepth: UInt32
    var rotation: UInt32
}

struct SDRVideoRendererView: UIViewRepresentable {
    let player: AVPlayer
    let rotation: VideoFrameRotation

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, rotation: rotation)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.update(player: player, rotation: rotation)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        uiView.delegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private var player: AVPlayer
        private var rotation: VideoFrameRotation
        private var attachedItem: AVPlayerItem?
        private var output: AVPlayerItemVideoOutput?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var textureCache: CVMetalTextureCache?
        private var sourceTextureReference: CVMetalTexture?
        private var sourcePixelBuffer: CVPixelBuffer?
        private var sourceTexture: MTLTexture?

        init(player: AVPlayer, rotation: VideoFrameRotation) {
            self.player = player
            self.rotation = rotation
        }

        func attach(to view: MTKView) {
            guard let device = view.device else { return }
            commandQueue = device.makeCommandQueue()
            guard let library = device.makeDefaultLibrary(),
                  let vertex = library.makeFunction(name: "generatedStereoVertex"),
                  let fragment = library.makeFunction(name: "sdrVideoFragment") else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "SDR Video Renderer"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
            let status = CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                device,
                nil,
                &textureCache
            )
            guard status == kCVReturnSuccess, pipelineState != nil else { return }
            attachOutput(to: player.currentItem)
            view.delegate = self
        }

        func update(player: AVPlayer, rotation: VideoFrameRotation) {
            self.player = player
            self.rotation = rotation
            if attachedItem !== player.currentItem {
                attachOutput(to: player.currentItem)
            }
        }

        func detach() {
            if let output, let attachedItem {
                attachedItem.remove(output)
            }
            attachedItem = nil
            output = nil
            sourceTextureReference = nil
            sourcePixelBuffer = nil
            sourceTexture = nil
            if let textureCache {
                CVMetalTextureCacheFlush(textureCache, 0)
            }
            textureCache = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let output,
                  let commandQueue,
                  let pipelineState,
                  let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pixelBuffer = output.copyPixelBuffer(
                   forItemTime: itemTime,
                   itemTimeForDisplay: nil
               ) {
                updateSourceTexture(from: pixelBuffer)
            }

            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            descriptor.colorAttachments[0].storeAction = .store
            guard let sourceTexture,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }

            encoder.label = "SDR Video Frame"
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            var uniforms = SDRVideoUniforms(
                sourceSize: SIMD2(Float(sourceTexture.width), Float(sourceTexture.height)),
                targetSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                rotation: rotation.rawValue,
                padding: 0
            )
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<SDRVideoUniforms>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func attachOutput(to item: AVPlayerItem?) {
            if let output, let attachedItem {
                attachedItem.remove(output)
            }
            attachedItem = item
            guard let item else {
                output = nil
                return
            }
            let output = AVPlayerItemVideoOutput(
                pixelBufferAttributes: SDRVideoOutputSettings.pixelBufferAttributes
            )
            item.add(output)
            self.output = output
        }

        private func updateSourceTexture(from pixelBuffer: CVPixelBuffer) {
            guard let textureCache else { return }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var textureReference: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &textureReference
            )
            guard status == kCVReturnSuccess,
                  let textureReference,
                  let texture = CVMetalTextureGetTexture(textureReference) else { return }
            sourcePixelBuffer = pixelBuffer
            sourceTextureReference = textureReference
            sourceTexture = texture
        }
    }
}

private struct SDRVideoUniforms {
    var sourceSize: SIMD2<Float>
    var targetSize: SIMD2<Float>
    var rotation: UInt32
    var padding: UInt32
}

private enum StereoRendererError: LocalizedError {
    case missingShader
    case textureCacheCreationFailed
    case depthTextureCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingShader: "The AI 3D Metal shaders could not be loaded."
        case .textureCacheCreationFailed: "The video texture cache could not be created."
        case .depthTextureCreationFailed: "A fallback depth texture could not be created."
        }
    }
}
