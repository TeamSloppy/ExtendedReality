import XCTest
@testable import ExtendReality

final class HeadPoseSmootherTests: XCTestCase {
    func testFirstSamplePassesThrough() {
        var smoother = HeadPoseSmoother(responseTime: 0.025)
        let sample = HeadPose(yaw: 12, pitch: -3, roll: 2, timestamp: 1)

        XCTAssertEqual(smoother.filter(sample), sample)
    }

    func testLaterSampleIsSmoothedWithoutOvershoot() {
        var smoother = HeadPoseSmoother(responseTime: 0.025)
        _ = smoother.filter(.identity)
        let result = smoother.filter(
            HeadPose(yaw: 30, pitch: 10, roll: -8, timestamp: 0.01)
        )

        XCTAssertGreaterThan(result.yaw, 0)
        XCTAssertLessThan(result.yaw, 30)
        XCTAssertGreaterThan(result.pitch, 0)
        XCTAssertLessThan(result.pitch, 10)
        XCTAssertLessThan(result.roll, 0)
        XCTAssertGreaterThan(result.roll, -8)
    }

    func testAngleSmoothingUsesShortestPathAcrossWrapBoundary() {
        var smoother = HeadPoseSmoother(responseTime: 0.025)
        _ = smoother.filter(HeadPose(yaw: 179, pitch: 0, roll: 0, timestamp: 1))
        let result = smoother.filter(
            HeadPose(yaw: -179, pitch: 0, roll: 0, timestamp: 1.01)
        )

        XCTAssertGreaterThan(result.yaw, 179)
        XCTAssertLessThan(result.yaw, 181)
    }

    func testResetMakesNextSampleImmediate() {
        var smoother = HeadPoseSmoother(responseTime: 1)
        _ = smoother.filter(.identity)
        smoother.reset()
        let sample = HeadPose(yaw: 20, pitch: 4, roll: 1, timestamp: 1)

        XCTAssertEqual(smoother.filter(sample), sample)
    }
}
