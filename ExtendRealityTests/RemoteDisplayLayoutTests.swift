import XCTest
@testable import ExtendReality

final class RemoteDisplayLayoutTests: XCTestCase {
    func testLayoutsHaveStableStoredValues() {
        XCTAssertEqual(RemoteDisplayLayout.allCases.map(\.rawValue), [
            "single",
            "multiple",
            "ultrawide",
        ])
    }

    func testStoredLayoutRoundTripsThroughUserDefaults() throws {
        let suiteName = "RemoteDisplayLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(RemoteDisplayLayout.ultrawide.rawValue, forKey: RemoteDisplayLayout.defaultsKey)

        let storedValue = try XCTUnwrap(defaults.string(forKey: RemoteDisplayLayout.defaultsKey))
        XCTAssertEqual(RemoteDisplayLayout(rawValue: storedValue), .ultrawide)
    }

    func testEveryLayoutHasAccessiblePresentationMetadata() {
        for layout in RemoteDisplayLayout.allCases {
            XCTAssertFalse(layout.title.isEmpty)
            XCTAssertFalse(layout.detail.isEmpty)
            XCTAssertFalse(layout.systemImage.isEmpty)
        }
    }
}
