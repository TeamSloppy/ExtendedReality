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

    func testPoseOffsetUsesShortestPathAcrossWrapBoundary() {
        let pose = HeadPose(yaw: -179, pitch: 8, roll: -4, timestamp: 2)
        let reference = HeadPose(yaw: 179, pitch: 3, roll: 2, timestamp: 1)

        let offset = pose.offset(relativeTo: reference)

        XCTAssertEqual(offset.yaw, 2)
        XCTAssertEqual(offset.pitch, 5)
        XCTAssertEqual(offset.roll, -6)
        XCTAssertEqual(offset.timestamp, pose.timestamp)
    }
}

@MainActor
final class HeadPoseControllerTests: XCTestCase {
    func testTrackingIsEnabledByDefault() {
        let defaults = makeDefaults()
        let provider = HeadPoseControllerTestProvider()

        let controller = HeadPoseController(
            provider: provider,
            defaults: defaults
        )

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.isTracking)
        XCTAssertEqual(controller.statusText, "Test 3DoF active")
    }

    func testDisablingTrackingIsPersistedAndUsesHeadLockedPose() {
        let defaults = makeDefaults()
        let provider = HeadPoseControllerTestProvider()
        let controller = HeadPoseController(
            provider: provider,
            defaults: defaults
        )

        controller.setEnabled(false)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.isTracking)
        XCTAssertEqual(controller.pose, .identity)
        XCTAssertEqual(controller.statusText, "3DoF disabled")
        XCTAssertFalse(defaults.bool(forKey: HeadPoseController.isEnabledDefaultsKey))

        let restored = HeadPoseController(
            provider: HeadPoseControllerTestProvider(),
            defaults: defaults
        )
        XCTAssertFalse(restored.isEnabled)
        XCTAssertFalse(restored.isTracking)
    }

    func testEnablingTrackingRecentersProvider() {
        let defaults = makeDefaults()
        defaults.set(
            false,
            forKey: HeadPoseController.isEnabledDefaultsKey
        )
        let provider = HeadPoseControllerTestProvider()
        let controller = HeadPoseController(
            provider: provider,
            defaults: defaults
        )

        controller.setEnabled(true)

        XCTAssertTrue(controller.isEnabled)
        XCTAssertTrue(controller.isTracking)
        XCTAssertEqual(controller.pose, .identity)
        XCTAssertEqual(provider.recenterCallCount, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HeadPoseControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

@MainActor
private final class HeadPoseControllerTestProvider: HeadPoseProvider {
    let displayName = "Test"
    let availability = HeadPoseAvailability.available
    private(set) var recenterCallCount = 0

    func eventStream() -> AsyncStream<HeadPoseEvent> {
        AsyncStream { continuation in
            continuation.yield(.availability(.available))
        }
    }

    func recenter() {
        recenterCallCount += 1
    }
}
