import XCTest
@testable import ExtendReality

final class DebugWorldTrackingPolicyTests: XCTestCase {
    func testWorldTrackingRequiresExplicitRequest() {
        XCTAssertFalse(
            DebugWorldTrackingPolicy.shouldStart(
                isRequested: false,
                isSupported: true,
                isSimulator: false
            )
        )
    }

    func testWorldTrackingNeverStartsOnSimulator() {
        XCTAssertFalse(
            DebugWorldTrackingPolicy.shouldStart(
                isRequested: true,
                isSupported: true,
                isSimulator: true
            )
        )
    }

    func testWorldTrackingRequiresDeviceSupport() {
        XCTAssertFalse(
            DebugWorldTrackingPolicy.shouldStart(
                isRequested: true,
                isSupported: false,
                isSimulator: false
            )
        )
    }

    func testWorldTrackingStartsWhenRequestedOnSupportedDevice() {
        XCTAssertTrue(
            DebugWorldTrackingPolicy.shouldStart(
                isRequested: true,
                isSupported: true,
                isSimulator: false
            )
        )
    }
}
