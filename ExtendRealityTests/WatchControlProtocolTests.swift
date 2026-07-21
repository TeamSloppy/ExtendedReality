import XCTest
@testable import ExtendReality

final class WatchControlProtocolTests: XCTestCase {
    func testWristPointerIgnoresTheInitialSampleAndMicroMovements() {
        var processor = WristPointerMotionProcessor()

        XCTAssertNil(
            processor.consume(
                rotationRateX: 0,
                rotationRateY: 0,
                timestamp: 10,
                sensitivity: 1,
                invertVertical: false
            )
        )
        XCTAssertNil(
            processor.consume(
                rotationRateX: 0.03,
                rotationRateY: 0.04,
                timestamp: 10.04,
                sensitivity: 1,
                invertVertical: false
            )
        )
    }

    func testWristPointerUsesMotionTimestampsAndBatchesStableDeltas() {
        var processor = WristPointerMotionProcessor()
        _ = processor.consume(
            rotationRateX: 0,
            rotationRateY: 0,
            timestamp: 0,
            sensitivity: 1,
            invertVertical: false
        )

        XCTAssertNil(
            processor.consume(
                rotationRateX: 0,
                rotationRateY: 1,
                timestamp: 0.02,
                sensitivity: 1,
                invertVertical: false
            )
        )
        let delta = processor.consume(
            rotationRateX: 0,
            rotationRateY: 1,
            timestamp: 0.04,
            sensitivity: 1,
            invertVertical: false
        )

        XCTAssertNotNil(delta)
        XCTAssertGreaterThan(delta?.x ?? 0, 0)
        XCTAssertEqual(delta?.y ?? .nan, 0, accuracy: 0.000_001)
    }

    func testWristPointerLimitsSpikesAndResetsAfterAPause() {
        var processor = WristPointerMotionProcessor()
        _ = processor.consume(
            rotationRateX: 0,
            rotationRateY: 0,
            timestamp: 0,
            sensitivity: 1,
            invertVertical: false
        )

        let spike = processor.consume(
            rotationRateX: 0,
            rotationRateY: 100,
            timestamp: 0.04,
            sensitivity: 1,
            invertVertical: false
        )
        XCTAssertLessThan(spike?.x ?? .infinity, 0.04)
        XCTAssertNil(
            processor.consume(
                rotationRateX: 0,
                rotationRateY: 1,
                timestamp: 0.3,
                sensitivity: 1,
                invertVertical: false
            )
        )
    }

    func testWristPointerCanInvertVerticalMovement() {
        var positive = WristPointerMotionProcessor()
        var negative = WristPointerMotionProcessor()
        _ = positive.consume(rotationRateX: 1, rotationRateY: 0, timestamp: 0, sensitivity: 1, invertVertical: false)
        _ = negative.consume(rotationRateX: 1, rotationRateY: 0, timestamp: 0, sensitivity: 1, invertVertical: true)
        let positiveDelta = positive.consume(rotationRateX: 1, rotationRateY: 0, timestamp: 0.04, sensitivity: 1, invertVertical: false)
        let negativeDelta = negative.consume(rotationRateX: 1, rotationRateY: 0, timestamp: 0.04, sensitivity: 1, invertVertical: true)

        XCTAssertGreaterThan(positiveDelta?.y ?? 0, 0)
        XCTAssertLessThan(negativeDelta?.y ?? 0, 0)
    }

    func testPointerCommandRoundTrip() {
        let expected = WatchControlCommand.pointerDelta(x: 0.12, y: -0.4)
        XCTAssertEqual(WatchControlCommand(dictionary: expected.dictionary), expected)
    }

    func testVoiceAssistantCommandRoundTrip() {
        let expected = WatchControlCommand.toggleVoiceAssistant
        XCTAssertEqual(WatchControlCommand(dictionary: expected.dictionary), expected)
        XCTAssertEqual(expected.dictionary["command"] as? String, "toggleVoiceAssistant")
    }

    func testPlaybackCommandsRoundTrip() {
        let toggle = WatchControlCommand.togglePlayback
        let seek = WatchControlCommand.seekPlayback(seconds: -10)

        XCTAssertEqual(WatchControlCommand(dictionary: toggle.dictionary), toggle)
        XCTAssertEqual(WatchControlCommand(dictionary: seek.dictionary), seek)
    }

    func testWorkspaceSnapshotRoundTrip() {
        let window = WatchWindowSummary(
            id: UUID(),
            title: "Browser",
            kind: "browser",
            isMinimized: false
        )
        let expected = WatchWorkspaceSnapshot(
            activeWindowID: window.id,
            windows: [window],
            trackingStatus: "AirPods 3DoF active",
            isTracking: true,
            playback: WatchPlaybackState(windowID: window.id, isPlaying: true)
        )

        XCTAssertEqual(WatchWorkspaceSnapshot(dictionary: expected.dictionary), expected)
    }
}
