import CoreGraphics
import ImageIO
import UIKit
import XCTest
@testable import ExtendReality

final class WindowProjectionTests: XCTestCase {
    func testCenteredWindowProjectsToViewportCenter() {
        let viewport = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = WindowProjection.frame(for: .centered, in: viewport)

        XCTAssertEqual(frame.midX, viewport.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, viewport.midY, accuracy: 0.001)
        XCTAssertGreaterThan(frame.width, 1000)
    }

    func testRightwardHeadTurnMovesWorldLockedWindowLeft() {
        let viewport = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let neutral = WindowProjection.frame(for: .centered, in: viewport)
        let turned = WindowProjection.frame(
            for: .centered,
            in: viewport,
            headPose: HeadPose(yaw: -10, pitch: 0, roll: 0, timestamp: 1)
        )

        XCTAssertLessThan(turned.midX, neutral.midX)
    }

    func testGreaterVirtualDistanceProducesSmallerWindow() {
        let viewport = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var transform = WindowTransform3DoF.centered
        let near = WindowProjection.frame(for: transform, in: viewport)
        transform.virtualDistance = 1.5
        let far = WindowProjection.frame(for: transform, in: viewport)

        XCTAssertLessThan(far.width, near.width)
        XCTAssertLessThan(far.height, near.height)
    }

    func testHeadRollRotatesOffCenterWindowAroundViewportCenter() {
        let viewport = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var transform = WindowTransform3DoF.centered
        transform.yaw = 12
        let neutral = WindowProjection.frame(for: transform, in: viewport)
        let rolled = WindowProjection.frame(
            for: transform,
            in: viewport,
            headPose: HeadPose(yaw: 0, pitch: 0, roll: 20, timestamp: 1)
        )

        XCTAssertNotEqual(rolled.midY, neutral.midY, accuracy: 0.001)
    }

    func testTrackedVoiceAssistantLivesBelowNeutralViewAndCentersWhenLookingDown() throws {
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let anchor = VoiceAssistantPlacement.anchor(below: .identity)
        let neutral = try XCTUnwrap(
            VoiceAssistantPlacement.position(
                for: anchor,
                in: viewport,
                headPose: .identity,
                isTracking: true
            )
        )
        let lookingDown = try XCTUnwrap(
            VoiceAssistantPlacement.position(
                for: anchor,
                in: viewport,
                headPose: HeadPose(
                    yaw: 0,
                    pitch: anchor.pitch,
                    roll: 0,
                    timestamp: 1
                ),
                isTracking: true
            )
        )

        XCTAssertGreaterThan(neutral.y, viewport.maxY)
        XCTAssertEqual(lookingDown.x, viewport.midX, accuracy: 0.001)
        XCTAssertEqual(lookingDown.y, viewport.midY, accuracy: 0.001)
    }

    func testVoiceAssistantUsesScreenFixedFallbackWithoutTracking() {
        let anchor = VoiceAssistantPlacement.anchor(below: .identity)
        let position = VoiceAssistantPlacement.position(
            for: anchor,
            in: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            headPose: .identity,
            isTracking: false
        )

        XCTAssertNil(position)
    }

    func testVoiceAssistantAnchorIsCapturedBelowCurrentViewDirection() throws {
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let triggerPose = HeadPose(yaw: -12, pitch: -4, roll: 0, timestamp: 1)
        let anchor = VoiceAssistantPlacement.anchor(below: triggerPose)
        let lookingAtAssistant = HeadPose(
            yaw: triggerPose.yaw,
            pitch: triggerPose.pitch + VoiceAssistantPlacement.downwardPitchOffset,
            roll: 0,
            timestamp: 2
        )
        let position = try XCTUnwrap(
            VoiceAssistantPlacement.position(
                for: anchor,
                in: viewport,
                headPose: lookingAtAssistant,
                isTracking: true
            )
        )

        XCTAssertEqual(position.x, viewport.midX, accuracy: 0.001)
        XCTAssertEqual(position.y, viewport.midY, accuracy: 0.001)
    }

    func testSpatialDockLivesBelowHorizonAndCentersWhenLookingDown() throws {
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let neutral = try XCTUnwrap(
            SpatialDockPlacement.position(
                in: viewport,
                headPose: .identity,
                isTracking: true
            )
        )
        let lookingDown = try XCTUnwrap(
            SpatialDockPlacement.position(
                in: viewport,
                headPose: HeadPose(
                    yaw: 0,
                    pitch: SpatialDockPlacement.worldPitch,
                    roll: 0,
                    timestamp: 1
                ),
                isTracking: true
            )
        )

        XCTAssertGreaterThan(neutral.y, viewport.maxY)
        XCTAssertEqual(lookingDown.x, viewport.midX, accuracy: 0.001)
        XCTAssertEqual(lookingDown.y, viewport.midY, accuracy: 0.001)
    }

    func testSpatialDockUsesScreenFixedFallbackWithoutTracking() {
        XCTAssertNil(
            SpatialDockPlacement.position(
                in: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
                headPose: .identity,
                isTracking: false
            )
        )
    }

    func testUltrawideWindowMatchesStreamAspectWithoutLetterboxing() {
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let projected = WindowProjection.frame(for: .macStream, in: viewport)
        let fitted = WindowProjection.framePreservingContentAspect(
            projected,
            contentAspectRatio: 32.0 / 9.0,
            verticalChrome: WindowChromeLayout.verticalChromeHeight
        )
        let contentHeight = fitted.height - WindowChromeLayout.verticalChromeHeight

        XCTAssertEqual(fitted.midX, viewport.midX, accuracy: 0.001)
        XCTAssertEqual(fitted.width / contentHeight, 32.0 / 9.0, accuracy: 0.001)
        XCTAssertGreaterThan(fitted.width, 1_700)
    }

    func testStandardDisplayAspectIsNotCappedToViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let projected = WindowProjection.frame(for: .macStream, in: viewport)
        let fitted = WindowProjection.framePreservingContentAspect(
            projected,
            contentAspectRatio: 16.0 / 10.0,
            verticalChrome: WindowChromeLayout.verticalChromeHeight
        )
        let contentHeight = fitted.height - WindowChromeLayout.verticalChromeHeight

        XCTAssertGreaterThan(fitted.height, viewport.height * 0.80)
        XCTAssertEqual(fitted.width / contentHeight, 16.0 / 10.0, accuracy: 0.001)
    }

    func testLargeWindowCanProjectBeyondViewportWidth() {
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        var transform = WindowTransform3DoF.centered
        transform.width = 2.4
        transform.height = 1.6
        transform.clamp()

        let frame = WindowProjection.frame(for: transform, in: viewport)

        XCTAssertEqual(transform.width, 2.4, accuracy: 0.001)
        XCTAssertGreaterThan(frame.width, viewport.width)
    }

    func testCurvatureRequiresWindowToBeBothLargeAndDistant() {
        var distant = WindowTransform3DoF.centered
        distant.virtualDistance = WindowTransform3DoF.virtualDistanceRange.upperBound
        var large = WindowTransform3DoF.centered
        large.width = 1.8
        var largeAndDistant = large
        largeAndDistant.virtualDistance = WindowTransform3DoF.virtualDistanceRange.upperBound

        XCTAssertEqual(WindowProjection.curvatureAmount(for: distant), 0, accuracy: 0.001)
        XCTAssertEqual(WindowProjection.curvatureAmount(for: large), 0, accuracy: 0.001)
        XCTAssertEqual(WindowProjection.curvatureAmount(for: largeAndDistant), 1, accuracy: 0.001)
    }

    func testSpatialCompositionAppliesRootTransformScaleAndDepth() throws {
        var window = WorkspaceWindow(title: "YouTube", source: .youtube(videoID: nil))
        window.appTransform = SpatialAppTransform3DoF(yaw: 4, pitch: -2, virtualDistance: 1, scale: 1.25)
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

        let panels = SpatialWindowCompositor.project(
            window: window,
            layout: .youtube,
            in: viewport
        )
        let info = try XCTUnwrap(panels.first(where: { $0.id == "info" }))
        let video = try XCTUnwrap(panels.first(where: { $0.id == "video" }))

        XCTAssertEqual(video.transform.yaw, 4, accuracy: 0.001)
        XCTAssertEqual(video.transform.width, 0.9, accuracy: 0.001)
        XCTAssertEqual(info.transform.yaw, 4 - 26 * 1.25, accuracy: 0.001)
        XCTAssertEqual(info.transform.virtualDistance, 1.1, accuracy: 0.001)
        XCTAssertLessThan(info.frame.midX, video.frame.midX)
    }

    func testSpatialCompositionBoundingFrameContainsEveryPanel() {
        let window = WorkspaceWindow(title: "YouTube", source: .youtube(videoID: nil))
        let panels = SpatialWindowCompositor.project(
            window: window,
            layout: .youtube,
            in: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        )
        let bounds = SpatialWindowCompositor.boundingFrame(for: panels)

        XCTAssertEqual(panels.count, 4)
        XCTAssertTrue(panels.allSatisfy { bounds.contains($0.frame) })
    }
}

final class SpatialPhotoDecoderTests: XCTestCase {
    func testStereoIndicesAreReadFromSpatialPhotoGroup() throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyGroups: [
                [
                    kCGImagePropertyGroupType: kCGImagePropertyGroupTypeStereoPair,
                    kCGImagePropertyGroupImageIndexLeft: 2,
                    kCGImagePropertyGroupImageIndexRight: 5,
                ]
            ]
        ]

        let indices = try XCTUnwrap(SpatialPhotoDecoder.stereoImageIndices(in: properties))

        XCTAssertEqual(indices, .init(left: 2, right: 5))
    }

    func testNonStereoGroupIsNotTreatedAsSpatialPhoto() {
        let properties: [CFString: Any] = [
            kCGImagePropertyGroups: [
                [
                    kCGImagePropertyGroupType: kCGImagePropertyGroupTypeAlternate,
                    kCGImagePropertyGroupImageIndexLeft: 0,
                    kCGImagePropertyGroupImageIndexRight: 1,
                ]
            ]
        ]

        XCTAssertNil(SpatialPhotoDecoder.stereoImageIndices(in: properties))
    }
}

@MainActor
final class MediaSessionTests: XCTestCase {
    func testOrdinaryPhotoUsesTwoDimensionalPresentation() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let data = try XCTUnwrap(image.pngData())
        let session = MediaSession()

        try session.loadPhotoData(data)

        XCTAssertNotNil(session.image)
        XCTAssertFalse(session.isSpatialPhoto)
        XCTAssertEqual(session.presentationMode, .twoDimensional)
    }
}
