import XCTest
@testable import ExtendReality

@MainActor
final class DashboardStoreTests: XCTestCase {
    func testDefaultDashboardContainsAppsBookmarksAndWidgets() {
        let defaults = makeDefaults()
        let store = DashboardStore(defaults: defaults, storageKey: #function)

        XCTAssertTrue(store.launchers.contains(where: { $0.content == .app(.gallery) }))
        XCTAssertTrue(store.launchers.contains(where: { $0.content == .app(.youtube) }))
        XCTAssertTrue(store.launchers.contains(where: {
            if case .bookmark = $0.content { return true }
            return false
        }))
        XCTAssertEqual(store.widgets.count, 3)
    }

    func testBookmarkIsNormalizedAndPersisted() throws {
        let defaults = makeDefaults()
        let key = #function
        let store = DashboardStore(defaults: defaults, storageKey: key)

        XCTAssertTrue(store.addBookmark(title: "Example", url: "example.com", accent: .green))

        let restored = DashboardStore(defaults: defaults, storageKey: key)
        let bookmark = try XCTUnwrap(restored.launchers.compactMap { item -> DashboardBookmark? in
            if case .bookmark(let bookmark) = item.content, bookmark.title == "Example" { return bookmark }
            return nil
        }.first)
        XCTAssertEqual(bookmark.url, "https://example.com")
        XCTAssertEqual(bookmark.accent, .green)
    }

    func testArbitraryLauncherCountCreatesAdditionalPages() {
        let store = DashboardStore(defaults: makeDefaults(), storageKey: #function)

        for index in 0 ..< 25 {
            XCTAssertTrue(store.addBookmark(title: "Site \(index)", url: "site\(index).example.com"))
        }

        XCTAssertGreaterThanOrEqual(store.pageCount, 4)
        XCTAssertFalse(store.launcherPage(3).isEmpty)
    }

    func testPageScrollIsClampedToAvailablePages() {
        let store = DashboardStore(defaults: makeDefaults(), storageKey: #function)
        for index in 0 ..< 14 {
            XCTAssertTrue(store.addBookmark(title: "Site \(index)", url: "site\(index).example.com"))
        }

        store.consumePageScroll(0.2)
        XCTAssertEqual(store.selectedPage, 1)
        store.consumePageScroll(-0.2)
        XCTAssertEqual(store.selectedPage, 0)
        store.consumePageScroll(-0.2)
        XCTAssertEqual(store.selectedPage, 0)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "DashboardStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
