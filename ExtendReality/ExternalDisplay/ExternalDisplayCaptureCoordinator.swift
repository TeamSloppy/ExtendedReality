@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Photos
import UIKit

@MainActor
@Observable
final class ExternalDisplayCaptureCoordinator {
    enum State: Equatable {
        case idle
        case recording
        case finishing
    }

    private(set) var state: State = .idle
    private(set) var lastCaptureURL: URL?
    private(set) var statusMessage: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private weak var sourceWindow: UIWindow?
    @ObservationIgnored private var movieWriter: ExternalDisplayMovieWriter?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var displayLinkProxy: DisplayLinkProxy?
    @ObservationIgnored private var firstFrameTimestamp: CFTimeInterval?

    var isAttached: Bool { sourceWindow != nil }
    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .finishing }

    func attach(window: UIWindow) {
        sourceWindow = window
        statusMessage = nil
        errorMessage = nil
    }

    func detach(window: UIWindow) {
        guard sourceWindow === window else { return }
        sourceWindow = nil
        guard state == .recording else { return }
        Task { @MainActor [weak self] in
            await self?.stopRecording()
        }
    }

    func captureScreenshot() async {
        guard state == .idle else { return }
        guard let sourceWindow else {
            fail(ExternalDisplayCaptureError.displayUnavailable)
            return
        }

        state = .finishing
        statusMessage = "Capturing the glasses display…"
        errorMessage = nil
        do {
            let outputURL = try Self.makeOutputURL(fileExtension: "png")
            let pixelSize = Self.pixelSize(
                for: sourceWindow,
                maximumDimension: 4_096
            )
            let image = try ExternalDisplayFrameRenderer.image(
                of: sourceWindow,
                pixelSize: pixelSize,
                afterScreenUpdates: true
            )
            guard let data = image.pngData() else {
                throw ExternalDisplayCaptureError.imageEncodingFailed
            }
            try data.write(to: outputURL, options: .atomic)
            await finishCapture(at: outputURL, kind: .photo)
        } catch {
            fail(error)
        }
    }

    func startRecording() {
        guard state == .idle else { return }
        guard let sourceWindow else {
            fail(ExternalDisplayCaptureError.displayUnavailable)
            return
        }

        do {
            let outputURL = try Self.makeOutputURL(fileExtension: "mp4")
            let pixelSize = Self.pixelSize(
                for: sourceWindow,
                maximumDimension: 1_920
            )
            let writer = try ExternalDisplayMovieWriter(
                outputURL: outputURL,
                pixelSize: pixelSize,
                framesPerSecond: 30
            )
            try writer.start()

            let proxy = DisplayLinkProxy(owner: self)
            let displayLink = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 15,
                maximum: 30,
                preferred: 30
            )
            displayLink.add(to: .main, forMode: .common)

            movieWriter = writer
            displayLinkProxy = proxy
            self.displayLink = displayLink
            firstFrameTimestamp = nil
            state = .recording
            statusMessage = "Recording the glasses display…"
            errorMessage = nil
            captureFrame(at: CACurrentMediaTime())
        } catch {
            fail(error)
        }
    }

    func stopRecording() async {
        guard state == .recording, let movieWriter else { return }
        state = .finishing
        stopDisplayLink()

        do {
            let outputURL = try await movieWriter.finish()
            self.movieWriter = nil
            await finishCapture(at: outputURL, kind: .video)
        } catch {
            self.movieWriter = nil
            fail(error)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func captureFrame(at timestamp: CFTimeInterval) {
        guard state == .recording,
              let sourceWindow,
              let movieWriter else { return }

        let firstTimestamp = firstFrameTimestamp ?? timestamp
        firstFrameTimestamp = firstTimestamp
        let presentationTime = CMTime(
            seconds: max(0, timestamp - firstTimestamp),
            preferredTimescale: 600
        )

        do {
            try movieWriter.append(window: sourceWindow, at: presentationTime)
        } catch {
            stopDisplayLink()
            state = .finishing
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = try? await movieWriter.finish()
                self.movieWriter = nil
                self.fail(error)
            }
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
        firstFrameTimestamp = nil
    }

    private func finishCapture(at outputURL: URL, kind: ExternalDisplayCaptureKind) async {
        lastCaptureURL = outputURL
        errorMessage = nil

        if await ExternalDisplayPhotoLibrary.add(outputURL, kind: kind) {
            statusMessage = kind == .photo
                ? "Screenshot saved to Photos."
                : "Recording saved to Photos."
        } else {
            statusMessage = "Capture is ready to share. Photos access was not granted."
        }
        state = .idle
    }

    private func fail(_ error: any Error) {
        stopDisplayLink()
        state = .idle
        statusMessage = nil
        errorMessage = error.localizedDescription
    }

    private static func pixelSize(
        for window: UIWindow,
        maximumDimension: CGFloat
    ) -> CGSize {
        let bounds = window.bounds.size
        let nativeScale = max(window.screen.nativeScale, 1)
        var width = max(bounds.width * nativeScale, 2)
        var height = max(bounds.height * nativeScale, 2)
        let longestSide = max(width, height)

        if longestSide > maximumDimension {
            let scale = maximumDimension / longestSide
            width *= scale
            height *= scale
        }

        return CGSize(
            width: max(2, Int(width.rounded()) & ~1),
            height: max(2, Int(height.rounded()) & ~1)
        )
    }

    private static func makeOutputURL(fileExtension: String) throws -> URL {
        let fileManager = FileManager.default
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = documents.appendingPathComponent("Glasses Captures", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let filename = "ExtendReality-\(formatter.string(from: .now)).\(fileExtension)"
        return directory.appendingPathComponent(filename)
    }

    @MainActor
    private final class DisplayLinkProxy: NSObject {
        weak var owner: ExternalDisplayCaptureCoordinator?

        init(owner: ExternalDisplayCaptureCoordinator) {
            self.owner = owner
        }

        @objc func tick(_ displayLink: CADisplayLink) {
            owner?.captureFrame(at: displayLink.timestamp)
        }
    }
}

private enum ExternalDisplayCaptureKind: Sendable {
    case photo
    case video
}

private enum ExternalDisplayPhotoLibrary {
    static func add(_ url: URL, kind: ExternalDisplayCaptureKind) async -> Bool {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else { return false }

        let changes: @Sendable () -> Void = {
            switch kind {
            case .photo:
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            case .video:
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }

        do {
            try await PHPhotoLibrary.shared().performChanges(changes)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
private final class ExternalDisplayMovieWriter {
    private let outputURL: URL
    private let pixelSize: CGSize
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(outputURL: URL, pixelSize: CGSize, framesPerSecond: Int) throws {
        self.outputURL = outputURL
        self.pixelSize = pixelSize
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: 8_000_000,
            AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            AVVideoMaxKeyFrameIntervalKey: framesPerSecond * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties,
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else {
            throw ExternalDisplayCaptureError.videoConfigurationFailed
        }
        writer.add(input)
    }

    func start() throws {
        guard writer.startWriting() else {
            throw writer.error ?? ExternalDisplayCaptureError.recordingStartFailed
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(window: UIWindow, at presentationTime: CMTime) throws {
        guard input.isReadyForMoreMediaData else { return }
        guard let pool = adaptor.pixelBufferPool else {
            throw ExternalDisplayCaptureError.pixelBufferUnavailable
        }

        var optionalBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer = optionalBuffer else {
            throw ExternalDisplayCaptureError.pixelBufferUnavailable
        }

        try ExternalDisplayFrameRenderer.render(
            window: window,
            into: pixelBuffer,
            pixelSize: pixelSize,
            afterScreenUpdates: false
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw writer.error ?? ExternalDisplayCaptureError.frameAppendFailed
        }
    }

    func finish() async throws -> URL {
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        guard writer.status == .completed else {
            throw writer.error ?? ExternalDisplayCaptureError.recordingFinishFailed
        }
        return outputURL
    }
}

@MainActor
private enum ExternalDisplayFrameRenderer {
    static func image(
        of window: UIWindow,
        pixelSize: CGSize,
        afterScreenUpdates: Bool
    ) throws -> UIImage {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw ExternalDisplayCaptureError.renderContextUnavailable
        }

        render(
            window: window,
            in: context,
            pixelSize: pixelSize,
            afterScreenUpdates: afterScreenUpdates
        )
        guard let cgImage = context.makeImage() else {
            throw ExternalDisplayCaptureError.imageEncodingFailed
        }
        return UIImage(cgImage: cgImage)
    }

    static func render(
        window: UIWindow,
        into pixelBuffer: CVPixelBuffer,
        pixelSize: CGSize,
        afterScreenUpdates: Bool
    ) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ExternalDisplayCaptureError.pixelBufferUnavailable
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: Int(pixelSize.width),
            height: Int(pixelSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw ExternalDisplayCaptureError.renderContextUnavailable
        }

        render(
            window: window,
            in: context,
            pixelSize: pixelSize,
            afterScreenUpdates: afterScreenUpdates
        )
    }

    private static func render(
        window: UIWindow,
        in context: CGContext,
        pixelSize: CGSize,
        afterScreenUpdates: Bool
    ) {
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: pixelSize))
        context.saveGState()
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(
            x: pixelSize.width / bounds.width,
            y: -pixelSize.height / bounds.height
        )
        UIGraphicsPushContext(context)
        let didDraw = window.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
        UIGraphicsPopContext()
        if !didDraw {
            window.layer.render(in: context)
        }
        context.restoreGState()
    }
}

private enum ExternalDisplayCaptureError: LocalizedError {
    case displayUnavailable
    case imageEncodingFailed
    case videoConfigurationFailed
    case recordingStartFailed
    case recordingFinishFailed
    case pixelBufferUnavailable
    case frameAppendFailed
    case renderContextUnavailable

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            "Connect the glasses display before starting a capture."
        case .imageEncodingFailed:
            "The glasses screenshot could not be encoded."
        case .videoConfigurationFailed:
            "The glasses recording could not be configured."
        case .recordingStartFailed:
            "The glasses recording could not start."
        case .recordingFinishFailed:
            "The glasses recording could not be finalized."
        case .pixelBufferUnavailable:
            "A video frame buffer could not be created."
        case .frameAppendFailed:
            "A glasses display frame could not be written."
        case .renderContextUnavailable:
            "The glasses display could not be rendered."
        }
    }
}
