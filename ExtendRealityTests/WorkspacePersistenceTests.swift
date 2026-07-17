import SwiftData
import XCTest
@testable import ExtendReality

@MainActor
final class WorkspacePersistenceTests: XCTestCase {
    func testWorkspaceRoundTrip() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let persistence = WorkspacePersistence(container: container)
        let expected = [
            WorkspaceWindow(
                title: "Mac",
                source: .remoteDesktop(host: "mac.local"),
                transform: .centered,
                zIndex: 4
            )
        ]

        persistence.save(expected)

        XCTAssertEqual(persistence.load(), expected)
    }

    func testRestoredWorkspaceStartsOnDashboardWithoutLosingWindows() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let persistence = WorkspacePersistence(container: container)
        persistence.save([
            WorkspaceWindow(
                title: "Browser",
                source: .browser(url: "https://example.com"),
                zIndex: 2
            )
        ])

        let store = WorkspaceStore(persistence: persistence)

        XCTAssertNil(store.activeWindowID)
        XCTAssertEqual(store.windows.count, 1)
        XCTAssertTrue(try XCTUnwrap(store.windows.first).isMinimized)
    }

    func testAppSwitcherSelectionRestoresFocusAndCentersWindow() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let browser = store.addWindow(kind: .browser)
        _ = store.addWindow(kind: .youtube)

        store.moveWindow(browser.id, normalizedDelta: CGVector(dx: 0.5, dy: -0.5))
        store.toggleMinimize(browser.id)
        store.toggleAppSwitcher()
        let headPose = HeadPose(yaw: -12, pitch: 7, roll: 3, timestamp: 1)
        store.focusAndCenter(browser.id, for: headPose)

        let selected = try XCTUnwrap(store.windows.first(where: { $0.id == browser.id }))
        XCTAssertEqual(store.activeWindowID, browser.id)
        XCTAssertFalse(selected.isMinimized)
        XCTAssertEqual(selected.transform.yaw, 12)
        XCTAssertEqual(selected.transform.pitch, 7)
        XCTAssertFalse(store.isAppSwitcherPresented)

        let projected = WindowProjection.frame(
            for: selected.transform,
            in: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            headPose: headPose
        )
        XCTAssertEqual(projected.midX, 960, accuracy: 0.001)
        XCTAssertEqual(projected.midY, 540, accuracy: 0.001)
    }

    func testRestoreMostRecentWindowLeavesDashboardForLatestWindow() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let browser = store.addWindow(kind: .browser)
        let gallery = store.addWindow(kind: .gallery)

        store.showDashboard()
        let restored = store.restoreMostRecentWindow()

        XCTAssertTrue(restored)
        XCTAssertEqual(store.activeWindowID, gallery.id)
        XCTAssertFalse(try XCTUnwrap(store.windows.first(where: { $0.id == gallery.id })).isMinimized)
        XCTAssertTrue(try XCTUnwrap(store.windows.first(where: { $0.id == browser.id })).isMinimized)
        XCTAssertFalse(store.isAppSwitcherPresented)
    }
}
