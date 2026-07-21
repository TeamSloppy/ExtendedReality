import AppKit
import ColorSync
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

struct DirectCaptureSource: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case display
        case application
    }

    let reference: MacCaptureSourceReference
    let kind: Kind
    var title: String
    var pixelSize: CGSize
    var globalFrame: CGRect
    var ownerProcessID: pid_t?

    var id: MacCaptureSourceReference { reference }
    var aspectRatio: Double { Double(pixelSize.width / max(pixelSize.height, 1)) }
}

enum MacDisplayIdentity {
    static func uuid(for displayID: CGDirectDisplayID) -> UUID? {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let value = unmanaged.takeRetainedValue()
        let string = CFUUIDCreateString(kCFAllocatorDefault, value) as String
        return UUID(uuidString: string)
    }
}

@MainActor
final class DirectCaptureCoordinator {
    private enum Target {
        case display(SCDisplay)
        case application(SCRunningApplication, display: SCDisplay, crop: CGRect)
    }

    private var targets: [MacCaptureSourceReference: Target] = [:]
    private var pipelines: [MacCaptureSourceReference: DirectCapturePipeline] = [:]
    private var excludedApplications: [SCRunningApplication] = []
    private(set) var sources: [DirectCaptureSource] = []

    var onFrame: ((MacCaptureSourceReference, CVPixelBuffer) -> Void)?
    var onFailure: ((String) -> Void)?

    func refresh(excludingOutputDisplayID: CGDirectDisplayID?) async throws -> [DirectCaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = content.displays.filter { $0.displayID != excludingOutputDisplayID }
        let ownApplications = content.applications.filter { $0.processID == ownPID }
        var nextTargets: [MacCaptureSourceReference: Target] = [:]
        var nextSources: [DirectCaptureSource] = []

        for display in displays {
            guard let uuid = MacDisplayIdentity.uuid(for: display.displayID) else { continue }
            let reference = MacCaptureSourceReference.display(uuid: uuid)
            let name = NSScreen.screens.first(where: { Self.displayID(for: $0) == display.displayID })?.localizedName
                ?? "Display \(display.displayID)"
            nextTargets[reference] = .display(display)
            nextSources.append(DirectCaptureSource(
                reference: reference,
                kind: .display,
                title: name,
                pixelSize: CGSize(width: display.width, height: display.height),
                globalFrame: display.frame,
                ownerProcessID: nil
            ))
        }

        let windowsByPID = Dictionary(grouping: content.windows.filter { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 64,
                  window.frame.height >= 64,
                  let app = window.owningApplication else { return false }
            return app.processID != ownPID
        }) { $0.owningApplication?.processID ?? 0 }

        for application in content.applications where application.processID != ownPID {
            guard !application.bundleIdentifier.isEmpty,
                  let windows = windowsByPID[application.processID],
                  let placement = Self.bestPlacement(for: windows, on: displays) else { continue }
            let reference = MacCaptureSourceReference.application(
                bundleIdentifier: application.bundleIdentifier
            )
            guard nextTargets[reference] == nil else { continue }
            let scale = max(
                Double(placement.display.width) / max(placement.display.frame.width, 1),
                1
            )
            let pixelSize = Self.evenSize(CGSize(
                width: placement.crop.width * scale,
                height: placement.crop.height * scale
            ))
            nextTargets[reference] = .application(
                application,
                display: placement.display,
                crop: placement.crop
            )
            nextSources.append(DirectCaptureSource(
                reference: reference,
                kind: .application,
                title: application.applicationName,
                pixelSize: pixelSize,
                globalFrame: CGRect(
                    x: placement.display.frame.minX + placement.crop.minX,
                    y: placement.display.frame.minY + placement.crop.minY,
                    width: placement.crop.width,
                    height: placement.crop.height
                ),
                ownerProcessID: application.processID
            ))
        }

        targets = nextTargets
        excludedApplications = ownApplications
        sources = nextSources.sorted {
            if $0.kind == $1.kind {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.kind == .display
        }
        return sources
    }

    func start(references: Set<MacCaptureSourceReference>) async throws {
        await stop()
        for reference in references {
            guard let target = targets[reference] else { continue }
            let pipeline: DirectCapturePipeline
            switch target {
            case .display(let display):
                pipeline = DirectCapturePipeline(
                    reference: reference,
                    display: display,
                    application: nil,
                    excludedApplications: excludedApplications,
                    sourceRect: nil,
                    outputSize: CGSize(width: display.width, height: display.height),
                    onFrame: frameHandler,
                    onFailure: failureHandler
                )
            case .application(let app, let display, let crop):
                let outputSize = sources.first(where: { $0.reference == reference })?.pixelSize
                    ?? crop.size
                pipeline = DirectCapturePipeline(
                    reference: reference,
                    display: display,
                    application: app,
                    excludedApplications: [],
                    sourceRect: crop,
                    outputSize: outputSize,
                    onFrame: frameHandler,
                    onFailure: failureHandler
                )
            }
            pipelines[reference] = pipeline
            do {
                try await pipeline.start()
            } catch {
                await stop()
                throw error
            }
        }
    }

    func stop() async {
        let active = Array(pipelines.values)
        pipelines.removeAll()
        for pipeline in active { await pipeline.stop() }
    }

    private var frameHandler: @Sendable (MacCaptureSourceReference, CVPixelBuffer) -> Void {
        { [weak self] reference, pixelBuffer in
            let box = PixelBufferBox(pixelBuffer)
            Task { @MainActor [weak self, box] in self?.onFrame?(reference, box.value) }
        }
    }

    private var failureHandler: @Sendable (String) -> Void {
        { [weak self] message in
            Task { @MainActor [weak self] in self?.onFailure?(message) }
        }
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func bestPlacement(
        for windows: [SCWindow],
        on displays: [SCDisplay]
    ) -> (display: SCDisplay, crop: CGRect)? {
        displays.compactMap { display -> (SCDisplay, CGRect, CGFloat)? in
            let intersections = windows
                .map { $0.frame.intersection(display.frame) }
                .filter { !$0.isNull && !$0.isEmpty }
            guard let first = intersections.first else { return nil }
            let union = intersections.dropFirst().reduce(first) { $0.union($1) }
            let padded = union.insetBy(dx: -12, dy: -12).intersection(display.frame)
            guard !padded.isNull, !padded.isEmpty else { return nil }
            let crop = CGRect(
                x: padded.minX - display.frame.minX,
                y: padded.minY - display.frame.minY,
                width: padded.width,
                height: padded.height
            )
            let area = intersections.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
            return (display, crop, area)
        }
        .max(by: { $0.2 < $1.2 })
        .map { ($0.0, $0.1) }
    }

    private static func evenSize(_ value: CGSize) -> CGSize {
        CGSize(
            width: max(2, floor(value.width / 2) * 2),
            height: max(2, floor(value.height / 2) * 2)
        )
    }
}

private final class PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}

private final class DirectCapturePipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let reference: MacCaptureSourceReference
    private let display: SCDisplay
    private let application: SCRunningApplication?
    private let excludedApplications: [SCRunningApplication]
    private let sourceRect: CGRect?
    private let outputSize: CGSize
    private let outputQueue = DispatchQueue(
        label: "com.vladprusakov.ExtendReality.direct-capture",
        qos: .userInteractive
    )
    private let onFrame: @Sendable (MacCaptureSourceReference, CVPixelBuffer) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var stream: SCStream?

    init(
        reference: MacCaptureSourceReference,
        display: SCDisplay,
        application: SCRunningApplication?,
        excludedApplications: [SCRunningApplication],
        sourceRect: CGRect?,
        outputSize: CGSize,
        onFrame: @escaping @Sendable (MacCaptureSourceReference, CVPixelBuffer) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.reference = reference
        self.display = display
        self.application = application
        self.excludedApplications = excludedApplications
        self.sourceRect = sourceRect
        self.outputSize = outputSize
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func start() async throws {
        let filter: SCContentFilter
        if let application {
            filter = SCContentFilter(display: display, including: [application], exceptingWindows: [])
        } else {
            filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(outputSize.width)
        configuration.height = Int(outputSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if let sourceRect {
            configuration.sourceRect = sourceRect
            configuration.includeChildWindows = true
        }

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
        onFrame(reference, pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFailure(error.localizedDescription)
    }
}
