import XCTest
@testable import ExtendReality

final class WatchControlProtocolTests: XCTestCase {
    func testPointerCommandRoundTrip() {
        let expected = WatchControlCommand.pointerDelta(x: 0.12, y: -0.4)
        XCTAssertEqual(WatchControlCommand(dictionary: expected.dictionary), expected)
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
            isTracking: true
        )

        XCTAssertEqual(WatchWorkspaceSnapshot(dictionary: expected.dictionary), expected)
    }
}
