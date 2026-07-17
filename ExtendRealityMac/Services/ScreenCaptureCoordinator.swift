@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import ScreenCaptureKit

@MainActor
final class ScreenCaptureCoordinator {
    private var pipelines: [CGDirectDisplayID: DisplayCapturePipeline] = [:]
    private var latestFrames: [CGDirectDisplayID: CGImage] = [:]
    private var layout: StreamLayout = .single
    private var orderedDisplayIDs: [CGDirectDisplayID] = []

    var onFramesChanged: (([CGDirectDisplayID: CGImage]) -> Void)?
    var onCompositeFrameChanged: ((CGImage?) -> Void)?
    var onFailure: ((String) -> Void)?

    func availableDisplays() async throws -> ([CaptureDisplay], [CGDirectDisplayID: SCDisplay]) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let sorted = content.displays.sorted { lhs, rhs in
            if lhs.frame.minX == rhs.frame.minX {
                return lhs.frame.minY < rhs.frame.minY
            }
            return lhs.frame.minX < rhs.frame.minX
        }

        let displays = sorted.enumerated().map { index, display in
            CaptureDisplay(
                id: display.displayID,
                name: displayName(for: display.displayID) ?? "Display \(index + 1)",
                width: display.width,
                height: display.height
            )
        }
        return (displays, Dictionary(uniqueKeysWithValues: sorted.map { ($0.displayID, $0) }))
    }

    func start(
        layout: StreamLayout,
        displays: [SCDisplay]
    ) async throws {
        await stop()
        guard !displays.isEmpty else { throw CaptureError.noDisplaysSelected }

        self.layout = layout
        orderedDisplayIDs = displays.map(\.displayID)

        do {
            for display in displays {
                let pipeline = DisplayCapturePipeline(display: display) { [weak self] displayID, image in
                    Task { @MainActor [weak self] in
                        self?.receive(image, from: displayID)
                    }
                } onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.onFailure?(message)
                    }
                }
                pipelines[display.displayID] = pipeline
                try await pipeline.start()
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        let activePipelines = Array(pipelines.values)
        pipelines.removeAll()
        latestFrames.removeAll()
        orderedDisplayIDs.removeAll()

        for pipeline in activePipelines {
            await pipeline.stop()
        }
        onFramesChanged?([:])
        onCompositeFrameChanged?(nil)
    }

    private func receive(_ image: CGImage, from displayID: CGDirectDisplayID) {
        guard pipelines[displayID] != nil else { return }
        latestFrames[displayID] = image

        switch layout {
        case .single, .multiple:
            onFramesChanged?(latestFrames)
            onCompositeFrameChanged?(nil)
        case .ultrawide:
            onFramesChanged?([:])
            onCompositeFrameChanged?(makeUltrawideFrame())
        }
    }

    private func makeUltrawideFrame() -> CGImage? {
        let images = orderedDisplayIDs.compactMap { latestFrames[$0] }
        guard images.count == orderedDisplayIDs.count else { return nil }

        let sourceSizes = images.map { CGSize(width: $0.width, height: $0.height) }
        let canvasSize = UltrawideLayout.canvasSize(for: sourceSizes)
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 0.04, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvasSize))

        let sourceTotalWidth = sourceSizes.reduce(0) { $0 + $1.width }
        let scale = canvasSize.width / sourceTotalWidth
        var x: CGFloat = 0

        for image in images {
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            let y = (canvasSize.height - height) / 2
            context.draw(image, in: CGRect(x: x, y: y, width: width, height: height))
            x += width
        }

        return context.makeImage()
    }

    private func displayName(for id: CGDirectDisplayID) -> String? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) else { return nil }
        return screen.localizedName
    }
}

private enum CaptureError: LocalizedError {
    case noDisplaysSelected

    var errorDescription: String? {
        switch self {
        case .noDisplaysSelected: "Select at least one display."
        }
    }
}

private final class DisplayCapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let display: SCDisplay
    private let outputQueue: DispatchQueue
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: @Sendable (CGDirectDisplayID, CGImage) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var stream: SCStream?

    init(
        display: SCDisplay,
        onFrame: @escaping @Sendable (CGDirectDisplayID, CGImage) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.display = display
        self.outputQueue = DispatchQueue(
            label: "com.vladprusakov.ExtendReality.capture.\(display.displayID)",
            qos: .userInteractive
        )
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() async throws {
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let outputSize = Self.outputSize(width: display.width, height: display.height)
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        onFrame(display.displayID, cgImage)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFailure(error.localizedDescription)
    }

    private static func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let maximumDimension = 2_560.0
        let largestDimension = Double(max(width, height))
        let scale = min(maximumDimension / largestDimension, 1)
        return (
            width: max(2, Int(Double(width) * scale) / 2 * 2),
            height: max(2, Int(Double(height) * scale) / 2 * 2)
        )
    }
}
