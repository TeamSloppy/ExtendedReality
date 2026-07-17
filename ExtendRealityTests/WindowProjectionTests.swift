import CoreGraphics
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
}
