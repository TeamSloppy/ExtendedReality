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

    func testWindowCanMoveCloserAndFartherWithinLimits() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .browser)

        store.zoomActiveWindow(by: 1.25)
        XCTAssertEqual(
            try XCTUnwrap(store.activeWindow).transform.virtualDistance,
            0.8,
            accuracy: 0.001
        )

        store.setWindowDistance(window.id, to: 100)
        XCTAssertEqual(
            try XCTUnwrap(store.activeWindow).transform.virtualDistance,
            WindowTransform3DoF.virtualDistanceRange.upperBound,
            accuracy: 0.001
        )

        store.adjustWindowDistance(window.id, by: -100)
        XCTAssertEqual(
            try XCTUnwrap(store.activeWindow).transform.virtualDistance,
            WindowTransform3DoF.virtualDistanceRange.lowerBound,
            accuracy: 0.001
        )
    }

    func testWindowResizeHasNoUpperSizeLimitButKeepsMinimumSize() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .browser)

        store.resizeWindow(window.id, normalizedDelta: 1)

        XCTAssertGreaterThan(try XCTUnwrap(store.activeWindow).transform.width, 0.95)
        XCTAssertGreaterThan(try XCTUnwrap(store.activeWindow).transform.height, 0.90)

        store.resizeWindow(window.id, normalizedDelta: -100)

        XCTAssertEqual(try XCTUnwrap(store.activeWindow).transform.width, 0.35, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.activeWindow).transform.height, 0.30, accuracy: 0.001)
    }

    func testWindowLayoutOrientationCanBeToggled() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .browser)

        store.toggleLayoutOrientation(window.id)
        XCTAssertEqual(try XCTUnwrap(store.activeWindow).effectiveLayoutOrientation, .vertical)
        XCTAssertLessThan(try XCTUnwrap(store.activeWindow).layoutContentAspectRatio, 1)

        store.toggleLayoutOrientation(window.id)
        XCTAssertEqual(try XCTUnwrap(store.activeWindow).effectiveLayoutOrientation, .horizontal)
        XCTAssertGreaterThan(try XCTUnwrap(store.activeWindow).layoutContentAspectRatio, 1)
    }

    func testExpandedWindowRestoresItsPreviousTransform() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .browser)
        let originalTransform = try XCTUnwrap(store.activeWindow).transform
        let headPose = HeadPose(yaw: -10, pitch: 4, roll: 0, timestamp: 1)

        store.toggleExpanded(window.id, for: headPose)
        XCTAssertTrue(store.isExpanded(window.id))
        XCTAssertEqual(try XCTUnwrap(store.activeWindow).transform.yaw, 10)
        XCTAssertEqual(try XCTUnwrap(store.activeWindow).transform.pitch, 4)

        store.toggleExpanded(window.id, for: headPose)
        XCTAssertFalse(store.isExpanded(window.id))
        XCTAssertEqual(try XCTUnwrap(store.activeWindow).transform, originalTransform)
    }

    func testLegacyWindowTransformDecodesIntoSpatialAppTransform() throws {
        struct LegacyWindow: Encodable {
            let id: UUID
            let title: String
            let source: WindowSource
            let transform: WindowTransform3DoF
            let zIndex: Int
            let isMinimized: Bool
            let contentAspectRatio: Double?
            let layoutOrientation: WindowLayoutOrientation?
        }
        var transform = WindowTransform3DoF.centered
        transform.yaw = 9
        transform.pitch = -3
        transform.virtualDistance = 1.4
        transform.width = 1.08
        let data = try JSONEncoder().encode(
            LegacyWindow(
                id: UUID(),
                title: "Legacy",
                source: .browser(url: "https://example.com"),
                transform: transform,
                zIndex: 3,
                isMinimized: false,
                contentAspectRatio: nil,
                layoutOrientation: nil
            )
        )

        let decoded = try JSONDecoder().decode(WorkspaceWindow.self, from: data)

        XCTAssertEqual(decoded.appTransform.yaw, 9)
        XCTAssertEqual(decoded.appTransform.pitch, -3)
        XCTAssertEqual(decoded.appTransform.virtualDistance, 1.4)
        XCTAssertEqual(decoded.appTransform.scale, 1.5, accuracy: 0.001)
    }

    func testSpatialWindowClientAppliesLayoutsAtomically() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .browser)
        let client = SpatialWindowClient(windowID: window.id, workspace: store)
        let original = try XCTUnwrap(client.layout)
        var invalid = original
        invalid.panels.append(original.panels[0])

        XCTAssertThrowsError(try client.setLayout(invalid))
        XCTAssertEqual(client.layout, original)

        try client.setLayout(.youtube)
        XCTAssertEqual(client.layout?.panels.count, 4)
        store.moveWindow(window.id, normalizedDelta: CGVector(dx: 0.25, dy: -0.2))
        XCTAssertEqual(client.layout?.panels.count, 4)
    }
}
