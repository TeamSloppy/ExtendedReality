import CoreGraphics
import CoreVideo
import Foundation
import UIKit
import XCTest
@testable import ExtendReality

final class StereoDepthSettingsTests: XCTestCase {
    func testDisparityStrengthIsClampedToComfortRange() {
        XCTAssertEqual(StereoDepthSettings.clampedDisparityPercent(0), 0.25)
        XCTAssertEqual(StereoDepthSettings.clampedDisparityPercent(0.65), 0.65)
        XCTAssertEqual(StereoDepthSettings.clampedDisparityPercent(2), 1.25)
    }

    func testThermalPolicyReducesDepthCadenceAndStopsAtCritical() {
        XCTAssertEqual(StereoThermalPolicy.depthFramesPerSecond(for: .nominal), 24)
        XCTAssertEqual(StereoThermalPolicy.depthFramesPerSecond(for: .fair), 15)
        XCTAssertEqual(StereoThermalPolicy.depthFramesPerSecond(for: .serious), 10)
        XCTAssertNil(StereoThermalPolicy.depthFramesPerSecond(for: .critical))
    }

    func testFullSideBySideGeometryProducesTwo1920By1080Eyes() {
        let size = CGSize(width: 3_840, height: 1_080)

        XCTAssertTrue(StereoDisplayGeometry.isFullSideBySide(size))
        let frames = StereoDisplayGeometry.eyeFrames(in: size)
        XCTAssertEqual(frames.left, CGRect(x: 0, y: 0, width: 1_920, height: 1_080))
        XCTAssertEqual(frames.right, CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080))
        XCTAssertFalse(StereoDisplayGeometry.isFullSideBySide(CGSize(width: 1_920, height: 1_080)))
    }

    func testVideoFrameRotationFollowsTrackPreferredTransform() {
        XCTAssertEqual(
            VideoFrameRotation(preferredTransform: .identity),
            .none
        )
        XCTAssertEqual(
            VideoFrameRotation(
                preferredTransform: CGAffineTransform(
                    translationX: 1_920,
                    y: 0
                ).rotated(by: .pi / 2)
            ),
            .clockwise90
        )
        XCTAssertEqual(
            VideoFrameRotation(
                preferredTransform: CGAffineTransform(rotationAngle: -.pi / 2)
            ),
            .counterclockwise90
        )
        XCTAssertEqual(
            VideoFrameRotation(
                preferredTransform: CGAffineTransform(rotationAngle: .pi)
            ),
            .halfTurn
        )
        XCTAssertTrue(VideoFrameRotation.clockwise90.swapsDimensions)
        XCTAssertFalse(VideoFrameRotation.halfTurn.swapsDimensions)
    }
}

final class StereoDepthMathTests: XCTestCase {
    func testPercentileBoundsRejectExtremeOutliers() throws {
        let values = [Float](repeating: 10, count: 50)
            + [Float](repeating: 20, count: 900)
            + [Float](repeating: 30, count: 50)
            + [-10_000, 10_000]

        let bounds = try XCTUnwrap(StereoDepthMath.percentileBounds(values))

        XCTAssertGreaterThan(bounds.lower, -100)
        XCTAssertLessThan(bounds.upper, 100)
        XCTAssertLessThan(bounds.lower, bounds.upper)
    }

    func testNormalizationClampsValuesAndUsesMidRange() {
        let values = StereoDepthMath.normalize(
            [-10, 0, 5, 10, 20],
            bounds: .init(lower: 0, upper: 10)
        )

        XCTAssertEqual(values, [0, 0, 0.5, 1, 1])
    }

    func testTemporalBlendStabilizesSmallChangesButPreservesLargeMotion() {
        let blended = StereoDepthMath.temporallyBlend(
            current: [0.55, 0.9],
            previous: [0.5, 0.1]
        )

        XCTAssertEqual(blended[0], 0.514, accuracy: 0.001)
        XCTAssertEqual(blended[1], 0.9, accuracy: 0.001)
    }

    func testHistogramDistanceDetectsSceneChange() {
        XCTAssertEqual(
            StereoDepthMath.histogramDistance([1, 0, 0], [1, 0, 0]),
            0
        )
        XCTAssertEqual(
            StereoDepthMath.histogramDistance([1, 0, 0], [0, 0, 1]),
            1
        )
    }
}

final class StereoDepthModelSmokeTests: XCTestCase {
    func testBundledModelProducesNormalizedDepthTexture() async throws {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            640,
            360,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let source = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(source, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(source) {
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(source)
            for y in 0 ..< 360 {
                for x in 0 ..< 640 {
                    let pixel = bytes.advanced(by: y * bytesPerRow + x * 4)
                    pixel[0] = UInt8((x + y) % 256)
                    pixel[1] = UInt8((x / 3 + y * 2) % 256)
                    pixel[2] = UInt8((x * 2 + y / 2) % 256)
                    pixel[3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(source, [])

        let frame = try await StereoDepthEstimator().estimate(
            StereoPixelBuffer(value: source)
        )

        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertEqual(
            frame.normalizedFloat16.count,
            frame.width * frame.height * MemoryLayout<Float16>.stride
        )
        XCTAssertTrue(frame.resetsHistory)
    }
}

@MainActor
final class GeneratedStereoMediaSessionTests: XCTestCase {
    func testOrdinaryPhotoDoesNotOfferGeneratedStereo() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let session = MediaSession()

        try session.loadPhotoData(try XCTUnwrap(image.pngData()))

        XCTAssertEqual(session.availablePresentationModes, [.twoDimensional])
        session.setPresentationMode(.generatedStereo)
        XCTAssertEqual(session.presentationMode, .twoDimensional)
    }
}
