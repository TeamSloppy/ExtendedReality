@preconcurrency import AVFoundation
import CoreImage
import CoreML
import CoreVideo
import Foundation

enum GeneratedStereoStatus: Equatable, Sendable {
    case idle
    case preparing
    case active
    case thermallyDegraded
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: "AI 3D is off"
        case .preparing: "Preparing AI 3D…"
        case .active: "AI 3D is active"
        case .thermallyDegraded: "AI 3D quality reduced"
        case .unavailable(let message), .failed(let message): message
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "view.3d"
        case .preparing: "sparkles"
        case .active: "view.3d"
        case .thermallyDegraded: "thermometer.medium"
        case .unavailable: "view.3d.slash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var isError: Bool {
        switch self {
        case .unavailable, .failed: true
        default: false
        }
    }
}

enum StereoDepthSettings {
    static let defaultDisparityPercent = 0.65
    static let disparityPercentRange = 0.25 ... 1.25

    static func clampedDisparityPercent(_ value: Double) -> Double {
        min(max(value, disparityPercentRange.lowerBound), disparityPercentRange.upperBound)
    }
}

enum StereoThermalPolicy {
    static func depthFramesPerSecond(for state: ProcessInfo.ThermalState) -> Int? {
        switch state {
        case .nominal: 24
        case .fair: 15
        case .serious: 10
        case .critical: nil
        @unknown default: 15
        }
    }
}

enum StereoDisplayGeometry {
    static func isFullSideBySide(_ size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        return size.width / size.height >= 3.2
    }

    static func eyeFrames(in size: CGSize) -> (left: CGRect, right: CGRect) {
        let eyeWidth = size.width / 2
        return (
            CGRect(x: 0, y: 0, width: eyeWidth, height: size.height),
            CGRect(x: eyeWidth, y: 0, width: eyeWidth, height: size.height)
        )
    }
}

struct StereoVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let itemTime: CMTime
}

enum VideoFrameRotation: UInt32, Equatable, Sendable {
    case none = 0
    case clockwise90 = 1
    case halfTurn = 2
    case counterclockwise90 = 3

    init(preferredTransform transform: CGAffineTransform) {
        let quarterTurns = Int((atan2(transform.b, transform.a) / (.pi / 2)).rounded())
        switch (quarterTurns % 4 + 4) % 4 {
        case 1: self = .clockwise90
        case 2: self = .halfTurn
        case 3: self = .counterclockwise90
        default: self = .none
        }
    }

    var swapsDimensions: Bool {
        self == .clockwise90 || self == .counterclockwise90
    }
}

enum SDRVideoOutputSettings {
    static var pixelBufferAttributes: [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey as String:
                kCVImageBufferTransferFunction_ITU_R_709_2,
        ]
    }
}

@MainActor
protocol StereoFrameSource: AnyObject {
    func copyFrame(forHostTime hostTime: CFTimeInterval) -> StereoVideoFrame?
}

@MainActor
final class AVPlayerStereoFrameSource: StereoFrameSource {
    let output: AVPlayerItemVideoOutput

    init(item: AVPlayerItem) {
        output = AVPlayerItemVideoOutput(
            pixelBufferAttributes: SDRVideoOutputSettings.pixelBufferAttributes
        )
        item.add(output)
    }

    func copyFrame(forHostTime hostTime: CFTimeInterval) -> StereoVideoFrame? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(
                forItemTime: itemTime,
                itemTimeForDisplay: nil
              ) else { return nil }
        return StereoVideoFrame(pixelBuffer: pixelBuffer, itemTime: itemTime)
    }
}

struct StereoDepthFrame: Sendable {
    let sequence: UInt64
    let width: Int
    let height: Int
    let normalizedFloat16: Data
    let resetsHistory: Bool
}

struct StereoPixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

enum StereoDepthPipelineError: LocalizedError {
    case modelUnavailable
    case inputBufferCreationFailed
    case missingDepthOutput
    case unsupportedDepthFormat(OSType)
    case invalidDepthOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            "The bundled Depth Anything model could not be loaded."
        case .inputBufferCreationFailed:
            "A video frame could not be prepared for depth estimation."
        case .missingDepthOutput:
            "The depth model returned no depth image."
        case .unsupportedDepthFormat(let format):
            "The depth model returned unsupported pixel format \(format)."
        case .invalidDepthOutput(let details):
            "The depth model returned an invalid depth image: \(details)"
        }
    }
}

actor StereoDepthEstimator {
    static let inputSize = CGSize(width: 518, height: 392)

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var model: MLModel?
    private var previousDepth: [Float]?
    private var previousLuminanceHistogram: [Float]?
    private var sequence: UInt64 = 0

    func reset() {
        previousDepth = nil
        previousLuminanceHistogram = nil
    }

    func estimate(_ source: StereoPixelBuffer) throws -> StereoDepthFrame {
        let input = try makeModelInput(from: source.value)
        let histogram = StereoDepthMath.luminanceHistogram(inBGRA: input)
        let resetsHistory: Bool
        if let previousLuminanceHistogram {
            resetsHistory = StereoDepthMath.histogramDistance(
                histogram,
                previousLuminanceHistogram
            ) > 0.28
        } else {
            resetsHistory = true
        }
        previousLuminanceHistogram = histogram

        let model = try loadModel()
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: input),
        ])
        let result = try model.prediction(from: provider)
        guard let output = result.featureValue(for: "depth")?.imageBufferValue else {
            throw StereoDepthPipelineError.missingDepthOutput
        }

        let rawDepth = try StereoDepthMath.values(in: output)
        let expectedValueCount = CVPixelBufferGetWidth(output) * CVPixelBufferGetHeight(output)
        guard rawDepth.count == expectedValueCount else {
            throw StereoDepthPipelineError.invalidDepthOutput(
                "expected \(expectedValueCount) values but received \(rawDepth.count)"
            )
        }
        guard let bounds = StereoDepthMath.percentileBounds(rawDepth) else {
            let finite = rawDepth.filter(\.isFinite)
            throw StereoDepthPipelineError.invalidDepthOutput(
                "format \(CVPixelBufferGetPixelFormatType(output)), "
                    + "finite values \(finite.count)/\(rawDepth.count), "
                    + "range \(finite.min() ?? .nan)...\(finite.max() ?? .nan), "
                    + StereoDepthMath.storageSummary(in: output)
            )
        }
        let normalized = StereoDepthMath.normalize(rawDepth, bounds: bounds)
        let stabilized = StereoDepthMath.temporallyBlend(
            current: normalized,
            previous: resetsHistory ? nil : previousDepth
        )
        previousDepth = stabilized
        sequence &+= 1

        let float16 = stabilized.map(Float16.init)
        let data = float16.withUnsafeBufferPointer { buffer -> Data in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(
                bytes: baseAddress,
                count: buffer.count * MemoryLayout<Float16>.stride
            )
        }
        return StereoDepthFrame(
            sequence: sequence,
            width: CVPixelBufferGetWidth(output),
            height: CVPixelBufferGetHeight(output),
            normalizedFloat16: data,
            resetsHistory: resetsHistory
        )
    }

    private func loadModel() throws -> MLModel {
        if let model { return model }
        guard let url = Bundle.main.url(
            forResource: "DepthAnythingV2SmallF16",
            withExtension: "mlmodelc"
        ) else {
            throw StereoDepthPipelineError.modelUnavailable
        }
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        // Simulator has no Neural Engine. Forcing CPU avoids a Core ML
        // simulator path that can successfully return an all-zero FP16 image.
        configuration.computeUnits = .cpuOnly
#else
        configuration.computeUnits = .all
#endif
        let loaded = try MLModel(contentsOf: url, configuration: configuration)
        model = loaded
        return loaded
    }

    private func makeModelInput(from source: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = Int(Self.inputSize.width)
        let height = Int(Self.inputSize.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        var destination: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &destination
        )
        guard status == kCVReturnSuccess, let destination else {
            throw StereoDepthPipelineError.inputBufferCreationFailed
        }

        let image = CIImage(cvPixelBuffer: source)
        let translated = image.transformed(
            by: CGAffineTransform(
                translationX: -image.extent.minX,
                y: -image.extent.minY
            )
        )
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / max(image.extent.width, 1),
                y: CGFloat(height) / max(image.extent.height, 1)
            )
        )
        context.render(
            scaled,
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )
        return destination
    }
}

enum StereoDepthMath {
    struct Bounds: Equatable, Sendable {
        let lower: Float
        let upper: Float
    }

    static func percentileBounds(
        _ values: [Float],
        lowerPercentile: Float = 0.05,
        upperPercentile: Float = 0.95
    ) -> Bounds? {
        // Sorting every 518×392 output would waste CPU time. A uniformly
        // sampled order statistic is stable for dense depth maps and remains
        // robust when a few predictions are extreme outliers.
        let maximumSampleCount = 8_192
        let stride = max(values.count / maximumSampleCount, 1)
        var sample = [Float]()
        sample.reserveCapacity(min(values.count, maximumSampleCount + 1))
        for index in Swift.stride(from: 0, to: values.count, by: stride) {
            let value = values[index]
            if value.isFinite { sample.append(value) }
        }
        guard sample.count > 1 else { return nil }
        sample.sort()
        let lowerIndex = min(
            max(Int(Float(sample.count - 1) * lowerPercentile), 0),
            sample.count - 1
        )
        let upperIndex = min(
            max(Int(Float(sample.count - 1) * upperPercentile), 0),
            sample.count - 1
        )
        let lower = sample[lowerIndex]
        let upper = sample[upperIndex]
        guard upper - lower > 0.000_001 else { return nil }
        return Bounds(lower: lower, upper: upper)
    }

    static func normalize(_ values: [Float], bounds: Bounds) -> [Float] {
        let range = max(bounds.upper - bounds.lower, 0.000_001)
        return values.map { value in
            guard value.isFinite else { return 0.5 }
            return min(max((value - bounds.lower) / range, 0), 1)
        }
    }

    static func temporallyBlend(current: [Float], previous: [Float]?) -> [Float] {
        guard let previous, previous.count == current.count else { return current }
        return zip(current, previous).map { current, previous in
            let delta = abs(current - previous)
            let retainedPrevious: Float = if delta < 0.12 {
                0.72
            } else if delta < 0.25 {
                0.35
            } else {
                0
            }
            return previous * retainedPrevious + current * (1 - retainedPrevious)
        }
    }

    static func histogramDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1 }
        return zip(lhs, rhs).reduce(0) { $0 + abs($1.0 - $1.1) } / 2
    }

    static func luminanceHistogram(inBGRA pixelBuffer: CVPixelBuffer) -> [Float] {
        let binCount = 16
        var histogram = [Float](repeating: 0, count: binCount)
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return histogram
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return histogram }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var sampleCount: Float = 0
        for y in stride(from: 0, to: height, by: 8) {
            let row = bytes.advanced(by: y * bytesPerRow)
            for x in stride(from: 0, to: width, by: 8) {
                let pixel = row.advanced(by: x * 4)
                let luminance = 0.0722 * Float(pixel[0])
                    + 0.7152 * Float(pixel[1])
                    + 0.2126 * Float(pixel[2])
                let bin = min(Int(luminance / 256 * Float(binCount)), binCount - 1)
                histogram[bin] += 1
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return histogram }
        return histogram.map { $0 / sampleCount }
    }

    static func values(in pixelBuffer: CVPixelBuffer) throws -> [Float] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw StereoDepthPipelineError.invalidDepthOutput("the pixel buffer has no base address")
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        var values = [Float]()
        values.reserveCapacity(width * height)

        for y in 0 ..< height {
            let row = baseAddress.advanced(by: y * bytesPerRow)
            switch format {
            case kCVPixelFormatType_OneComponent8:
                let pixels = row.assumingMemoryBound(to: UInt8.self)
                values.append(contentsOf: (0 ..< width).map { Float(pixels[$0]) / 255 })
            case kCVPixelFormatType_OneComponent16Half:
                let pixels = row.assumingMemoryBound(to: UInt16.self)
                values.append(contentsOf: (0 ..< width).map {
                    Float(Float16(bitPattern: pixels[$0]))
                })
            case kCVPixelFormatType_OneComponent32Float:
                let pixels = row.assumingMemoryBound(to: Float.self)
                values.append(contentsOf: (0 ..< width).map { pixels[$0] })
            case kCVPixelFormatType_32BGRA:
                let pixels = row.assumingMemoryBound(to: UInt8.self)
                values.append(contentsOf: (0 ..< width).map { Float(pixels[$0 * 4]) / 255 })
            default:
                throw StereoDepthPipelineError.unsupportedDepthFormat(format)
            }
        }
        return values
    }

    static func storageSummary(in pixelBuffer: CVPixelBuffer) -> String {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent16Half
        else { return "storage not inspected" }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return "storage has no base address"
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var minimum = UInt16.max
        var maximum = UInt16.min
        for y in 0 ..< height {
            let pixels = baseAddress
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            for x in 0 ..< width {
                minimum = min(minimum, pixels[x])
                maximum = max(maximum, pixels[x])
            }
        }
        return "raw half bits \(minimum)...\(maximum)"
    }
}
