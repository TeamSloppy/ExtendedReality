@preconcurrency import AVFoundation
@preconcurrency import CoreImage
@preconcurrency import ScreenCaptureKit

@MainActor
struct CaptureApplicationTarget {
    let descriptor: CaptureApplication
    let application: SCRunningApplication
    let display: SCDisplay
}

@MainActor
final class ScreenCaptureCoordinator {
    private var pipelines: [CGDirectDisplayID: DisplayCapturePipeline] = [:]
    private var latestFrames: [CGDirectDisplayID: CGImage] = [:]
    private var layout: StreamLayout = .single
    private var orderedDisplayIDs: [CGDirectDisplayID] = []

    var onFramesChanged: (([CGDirectDisplayID: CGImage]) -> Void)?
    var onCompositeFrameChanged: ((CGImage?) -> Void)?
    var onAudioPCM: ((Data) -> Void)?
    var onFailure: ((String) -> Void)?

    func availableDisplays() async throws -> ([CaptureDisplay], [CGDirectDisplayID: SCDisplay]) {
        let content = try await shareableContent()
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

    func availableApplications() async throws -> ([CaptureApplication], [String: CaptureApplicationTarget]) {
        let content = try await shareableContent()
        let displays = content.displays
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let windowsByProcess = Dictionary(grouping: content.windows.filter { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 64,
                  window.frame.height >= 64,
                  let application = window.owningApplication else { return false }
            return application.processID != ownProcessID
        }) { window in
            window.owningApplication?.processID ?? 0
        }

        var targets: [String: CaptureApplicationTarget] = [:]
        for application in content.applications where application.processID != ownProcessID {
            guard let windows = windowsByProcess[application.processID],
                  let placement = bestPlacement(for: windows, on: displays) else { continue }
            let id = "pid:\(application.processID)"
            let scale = max(Double(placement.display.width) / max(placement.display.frame.width, 1), 1)
            let outputSize = StreamGeometry.captureSize(
                width: Int(placement.captureFrame.width * scale),
                height: Int(placement.captureFrame.height * scale)
            )
            let descriptor = CaptureApplication(
                id: id,
                name: application.applicationName,
                bundleIdentifier: application.bundleIdentifier,
                processID: application.processID,
                displayID: placement.display.displayID,
                captureFrame: placement.captureFrame,
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )
            targets[id] = CaptureApplicationTarget(
                descriptor: descriptor,
                application: application,
                display: placement.display
            )
        }

        let applications = targets.values
            .map(\.descriptor)
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        return (applications, targets)
    }

    func start(
        layout: StreamLayout,
        displays: [SCDisplay],
        showsCursor: Bool = true
    ) async throws {
        await stop()
        guard !displays.isEmpty else { throw CaptureError.noDisplaysSelected }

        self.layout = layout
        orderedDisplayIDs = displays.map(\.displayID)

        do {
            for (index, display) in displays.enumerated() {
                let audioHandler: (@Sendable (Data) -> Void)?
                if index == 0 {
                    audioHandler = { [weak self] data in
                        Task { @MainActor [weak self] in
                            self?.onAudioPCM?(data)
                        }
                    }
                } else {
                    audioHandler = nil
                }
                let pipeline = DisplayCapturePipeline(
                    display: display,
                    onFrame: { [weak self] displayID, image in
                        Task { @MainActor [weak self] in
                            self?.receive(image, from: displayID)
                        }
                    },
                    onAudioPCM: audioHandler,
                    onFailure: { [weak self] message in
                        Task { @MainActor [weak self] in
                            self?.onFailure?(message)
                        }
                    }
                )
                pipelines[display.displayID] = pipeline
                try await pipeline.start(showsCursor: showsCursor)
            }
        } catch {
            await stop()
            throw error
        }
    }

    func start(
        application target: CaptureApplicationTarget,
        showsCursor: Bool = true
    ) async throws {
        await stop()
        layout = .single
        orderedDisplayIDs = [target.display.displayID]

        let pipeline = DisplayCapturePipeline(
            display: target.display,
            application: target.application,
            sourceRect: target.descriptor.captureFrame,
            outputSize: CGSize(width: target.descriptor.width, height: target.descriptor.height),
            onFrame: { [weak self] displayID, image in
                Task { @MainActor [weak self] in
                    self?.receive(image, from: displayID)
                }
            },
            onAudioPCM: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.onAudioPCM?(data)
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.onFailure?(message)
                }
            }
        )
        pipelines[target.display.displayID] = pipeline
        do {
            try await pipeline.start(showsCursor: showsCursor)
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

    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    }

    private func bestPlacement(
        for windows: [SCWindow],
        on displays: [SCDisplay]
    ) -> (display: SCDisplay, captureFrame: CGRect)? {
        displays.compactMap { display -> (SCDisplay, CGRect, CGFloat)? in
            let intersections = windows
                .map { $0.frame.intersection(display.frame) }
                .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            guard let first = intersections.first else { return nil }
            let union = intersections.dropFirst().reduce(first) { $0.union($1) }
            let padded = union.insetBy(dx: -20, dy: -20).intersection(display.frame)
            guard !padded.isNull, padded.width > 0, padded.height > 0 else { return nil }
            let localFrame = CGRect(
                x: padded.minX - display.frame.minX,
                y: padded.minY - display.frame.minY,
                width: padded.width,
                height: padded.height
            )
            let coveredArea = intersections.reduce(CGFloat.zero) { partial, frame in
                partial + frame.width * frame.height
            }
            return (display, localFrame, coveredArea)
        }
        .max(by: { $0.2 < $1.2 })
        .map { ($0.0, $0.1) }
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
    private let application: SCRunningApplication?
    private let sourceRect: CGRect?
    private let outputSize: CGSize?
    private let outputQueue: DispatchQueue
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: @Sendable (CGDirectDisplayID, CGImage) -> Void
    private let onAudioPCM: (@Sendable (Data) -> Void)?
    private let onFailure: @Sendable (String) -> Void
    private let audioEncoder = SessionAudioPCMEncoder(
        channelCount: SessionAudioConfiguration.playbackChannels
    )
    private let cropBackgroundColor = CGColor(gray: 0.04, alpha: 1)
    private var stream: SCStream?

    init(
        display: SCDisplay,
        application: SCRunningApplication? = nil,
        sourceRect: CGRect? = nil,
        outputSize: CGSize? = nil,
        onFrame: @escaping @Sendable (CGDirectDisplayID, CGImage) -> Void,
        onAudioPCM: (@Sendable (Data) -> Void)?,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.display = display
        self.application = application
        self.sourceRect = sourceRect
        self.outputSize = outputSize
        self.outputQueue = DispatchQueue(
            label: "com.vladprusakov.ExtendReality.capture.\(display.displayID)",
            qos: .userInteractive
        )
        self.onFrame = onFrame
        self.onAudioPCM = onAudioPCM
        self.onFailure = onFailure
    }

    func start(showsCursor: Bool) async throws {
        let filter = if let application {
            SCContentFilter(
                display: display,
                including: [application],
                exceptingWindows: []
            )
        } else {
            SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
        }
        let configuration = SCStreamConfiguration()
        let outputSize = outputSize
            ?? StreamGeometry.captureSize(width: display.width, height: display.height)
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        if let sourceRect {
            configuration.sourceRect = sourceRect
            configuration.backgroundColor = cropBackgroundColor
            configuration.includeChildWindows = true
        }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = onAudioPCM != nil
        configuration.sampleRate = SessionAudioConfiguration.sampleRate
        configuration.channelCount = SessionAudioConfiguration.playbackChannels
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        if onAudioPCM != nil {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        }
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
        switch outputType {
        case .screen:
            guard sampleBuffer.isValid,
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
            onFrame(display.displayID, cgImage)
        case .audio:
            guard let data = audioEncoder.encode(sampleBuffer) else { return }
            onAudioPCM?(data)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFailure(error.localizedDescription)
    }

}
