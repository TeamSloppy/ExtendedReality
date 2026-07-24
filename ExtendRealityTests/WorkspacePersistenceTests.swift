import SwiftData
import XCTest
@testable import ExtendReality

@MainActor
final class WorkspacePersistenceTests: XCTestCase {
    func testPersistenceKeepsItsModelContainerAlive() throws {
        weak var container: ModelContainer?
        let persistence = try makePersistence { container = $0 }

        XCTAssertNotNil(container)

        let expected = WorkspacePersistenceState(
            windows: [WorkspaceWindow(title: "Preview", source: .gallery)]
        )
        persistence.save(expected)

        XCTAssertEqual(persistence.load(), expected)
    }

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
                zIndex: 4,
                attachmentMode: .follow
            )
        ]

        let expectedState = WorkspacePersistenceState(
            windows: expected,
            layoutMode: .stack,
            stackOrder: expected.map(\.id),
            stackTransform: WorkspaceStackTransform(
                centerYaw: 8,
                pitch: -3,
                virtualDistance: 1.2
            )
        )
        persistence.save(expectedState)

        XCTAssertEqual(persistence.load(), expectedState)
    }

    func testRestoredWorkspaceStartsWithDashboardOverWidgetsWithoutLosingWindows() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let persistence = WorkspacePersistence(container: container)
        let restoredWindow = WorkspaceWindow(
                title: "Browser",
                source: .browser(url: "https://example.com"),
                zIndex: 2
            )
        persistence.save(WorkspacePersistenceState(windows: [restoredWindow]))

        let store = WorkspaceStore(persistence: persistence)

        XCTAssertNil(store.activeWindowID)
        XCTAssertEqual(store.windows.count, 1)
        XCTAssertTrue(try XCTUnwrap(store.windows.first).isMinimized)
        XCTAssertEqual(store.presentationMode, .widgets)
        XCTAssertTrue(store.isDashboardPresented)
    }

    func testEmptyWorkspaceStartsWithDashboardOverWidgets() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))

        XCTAssertEqual(store.presentationMode, .widgets)
        XCTAssertTrue(store.isDashboardPresented)
        XCTAssertTrue(store.dismissDashboard())
        XCTAssertEqual(store.presentationMode, .widgets)
        XCTAssertFalse(store.isDashboardPresented)
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

    func testDashboardPresentationPreservesVisibleWindowsAndActiveWindow() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let browser = store.addWindow(kind: .browser)
        let gallery = store.addWindow(kind: .gallery)

        store.showDashboard()
        XCTAssertTrue(store.isDashboardPresented)
        let restored = store.dismissDashboard()

        XCTAssertTrue(restored)
        XCTAssertEqual(store.activeWindowID, gallery.id)
        XCTAssertEqual(store.presentationMode, .windows)
        XCTAssertFalse(store.isDashboardPresented)
        XCTAssertFalse(try XCTUnwrap(store.windows.first(where: { $0.id == gallery.id })).isMinimized)
        XCTAssertFalse(try XCTUnwrap(store.windows.first(where: { $0.id == browser.id })).isMinimized)
        XCTAssertFalse(store.isAppSwitcherPresented)
    }

    func testDashboardOverlayDoesNotSwitchBaseMode() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        XCTAssertEqual(store.presentationMode, .widgets)
        _ = store.dismissDashboard()
        store.showDashboard()
        XCTAssertEqual(store.presentationMode, .widgets)
        XCTAssertTrue(store.isDashboardPresented)
    }

    func testVerticalModesDismissDashboardInsteadOfIncludingItInModeOrder() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))

        XCTAssertTrue(store.isDashboardPresented)
        store.showWindows()
        XCTAssertEqual(store.presentationMode, .windows)
        XCTAssertFalse(store.isDashboardPresented)

        store.showDashboard()
        store.showWidgets()
        XCTAssertEqual(store.presentationMode, .widgets)
        XCTAssertFalse(store.isDashboardPresented)
    }

    func testAddingWindowFromDockPreservesExistingWindowPlacement() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let existing = store.addWindow(kind: .browser)
        store.moveWindow(existing.id, normalizedDelta: CGVector(dx: 0.35, dy: -0.2))
        let placement = try XCTUnwrap(store.activeWindow).appTransform
        let added = store.addWindow(kind: .gallery)

        let preserved = try XCTUnwrap(store.windows.first(where: { $0.id == existing.id }))
        XCTAssertEqual(preserved.appTransform, placement)
        XCTAssertFalse(preserved.isMinimized)
        XCTAssertEqual(store.activeWindowID, added.id)
    }

    func testDockFocusesAnExistingWindowThroughInputRouter() throws {
        let environment = AppEnvironment.preview(windowCount: 1)
        let existing = try XCTUnwrap(environment.workspace.windows.first)
        environment.workspace.moveWindow(
            existing.id,
            normalizedDelta: CGVector(dx: 0.3, dy: -0.15)
        )
        let existingPlacement = try XCTUnwrap(environment.workspace.activeWindow).appTransform
        environment.workspace.toggleMinimize(existing.id)
        let canvasSize = CGSize(width: 1_000, height: 1_000)
        environment.inputRouter.updateDockHitFrames(
            [.focus(existing.id): CGRect(x: 400, y: 400, width: 200, height: 200)],
            in: canvasSize
        )

        environment.inputRouter.movePointer(to: CGPoint(x: 0.5, y: 0.5), in: existing.id)
        environment.inputRouter.pointerDown(in: existing.id)
        environment.inputRouter.pointerUp(in: existing.id)

        XCTAssertEqual(environment.workspace.windows.count, 1)
        let preserved = try XCTUnwrap(
            environment.workspace.windows.first(where: { $0.id == existing.id })
        )
        XCTAssertEqual(preserved.appTransform, existingPlacement)
        XCTAssertFalse(preserved.isMinimized)
        XCTAssertEqual(environment.workspace.activeWindow?.source, .initial(for: .browser))
        XCTAssertEqual(environment.workspace.activeWindowID, existing.id)
    }

    func testOpeningAnExistingPWAReusesAndRestoresItsWindow() throws {
        let environment = AppEnvironment.preview(windowCount: 0)
        let installation = PWAInstallation(
            manifest: PWAAppManifest(
                id: "com.example.notes",
                name: "Notes",
                summary: "Offline notes",
                developer: "Example",
                version: "1.0.0",
                launchURL: URL(string: "https://notes.example.com")!,
                universalLink: URL(string: "https://notes.example.com/app")!,
                allowedOrigins: ["https://notes.example.com"],
                displayModes: [.window, .widget],
                requestedCapabilities: [],
                minimumAge: 4,
                accentHex: "#2563EB"
            ),
            installedAt: .now,
            dataStoreIdentifier: UUID(),
            grantedCapabilities: []
        )
        let first = environment.openPWA(installation, displayMode: .window)
        environment.workspace.moveWindow(
            first.id,
            normalizedDelta: CGVector(dx: 0.3, dy: -0.15)
        )
        let originalTransform = try XCTUnwrap(environment.workspace.activeWindow).appTransform
        environment.workspace.toggleMinimize(first.id)

        let reopened = environment.openPWA(installation, displayMode: .widget)

        XCTAssertEqual(reopened.id, first.id)
        XCTAssertEqual(environment.workspace.windows.count, 1)
        XCTAssertEqual(environment.workspace.activeWindowID, first.id)
        XCTAssertFalse(try XCTUnwrap(environment.workspace.activeWindow).isMinimized)
        XCTAssertEqual(environment.workspace.activeWindow?.appTransform, originalTransform)
        XCTAssertEqual(
            environment.workspace.activeWindow?.source,
            .pwa(installation, displayMode: .window)
        )
    }

    func testDashboardDoesNotSwitchWindowsMode() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        _ = store.addWindow(kind: .browser)
        store.showDashboard()

        XCTAssertEqual(store.presentationMode, .windows)
        XCTAssertTrue(store.isDashboardPresented)
    }

    func testDismissDashboardKeepsUnderlyingWidgetsModeWhenAllWindowsAreMinimized() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let browser = store.addWindow(kind: .browser)
        let gallery = store.addWindow(kind: .gallery)
        store.toggleMinimize(browser.id)
        store.toggleMinimize(gallery.id)

        XCTAssertEqual(store.presentationMode, .widgets)
        store.showDashboard()
        XCTAssertTrue(store.dismissDashboard())
        XCTAssertNil(store.activeWindowID)
        XCTAssertTrue(try XCTUnwrap(store.windows.first(where: { $0.id == gallery.id })).isMinimized)
        XCTAssertEqual(store.presentationMode, .widgets)
        XCTAssertFalse(store.isDashboardPresented)
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

    func testFocusAdjacentWindowCyclesAcrossVisibleWindows() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let first = store.addWindow(kind: .browser)
        let second = store.addWindow(kind: .gallery)
        let third = store.addWindow(kind: .youtube)

        XCTAssertEqual(store.activeWindowID, third.id)
        store.focusAdjacentWindow(by: 1)
        XCTAssertEqual(store.activeWindowID, first.id)
        store.focusAdjacentWindow(by: -1)
        XCTAssertEqual(store.activeWindowID, third.id)

        store.toggleMinimize(second.id)
        store.focus(first.id)
        store.focusAdjacentWindow(by: -1)
        XCTAssertEqual(store.activeWindowID, third.id)
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
        XCTAssertEqual(decoded.attachmentMode, .anchor)
    }

    func testLegacyWorkspaceArrayLoadsWithFreeAnchorDefaults() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let legacyWindow = WorkspaceWindow(
            title: "Legacy",
            source: .browser(url: "https://example.com")
        )
        let data = try JSONEncoder().encode([legacyWindow])
        container.mainContext.insert(WorkspaceSnapshot(data: data))
        try container.mainContext.save()

        let restored = WorkspacePersistence(container: container).load()

        XCTAssertEqual(restored.windows, [legacyWindow])
        XCTAssertEqual(restored.layoutMode, .freeSpace)
        XCTAssertEqual(restored.stackOrder, [legacyWindow.id])
        XCTAssertEqual(restored.stackTransform, .centered)
    }

    func testAttachmentModeSwitchPreservesVisiblePosition() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .browser)
        let pose = HeadPose(yaw: -12, pitch: 5, roll: 8, timestamp: 1)
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let anchored = try XCTUnwrap(
            store.presentations(for: store.windows, headPose: pose)[window.id]
        )
        let anchoredFrame = WindowProjection.frame(
            for: anchored.window.transform,
            in: viewport,
            headPose: anchored.projectionHeadPose
        )

        store.setAttachmentMode(.follow, for: window.id, headPose: pose)

        let following = try XCTUnwrap(
            store.presentations(for: store.windows, headPose: pose)[window.id]
        )
        let followingFrame = WindowProjection.frame(
            for: following.window.transform,
            in: viewport,
            headPose: following.projectionHeadPose
        )
        XCTAssertEqual(followingFrame.midX, anchoredFrame.midX, accuracy: 0.001)
        XCTAssertEqual(followingFrame.midY, anchoredFrame.midY, accuracy: 0.001)
        XCTAssertEqual(following.projectionHeadPose, .identity)
        XCTAssertEqual(following.rotationDegrees, 0)

        store.setAttachmentMode(.anchor, for: window.id, headPose: pose)
        let restored = try XCTUnwrap(store.activeWindow)
        XCTAssertEqual(restored.attachmentMode, .anchor)
        XCTAssertEqual(restored.appTransform.yaw, window.appTransform.yaw, accuracy: 0.001)
        XCTAssertEqual(restored.appTransform.pitch, window.appTransform.pitch, accuracy: 0.001)
    }

    func testSmoothFollowPreservesPositionThenEasesTowardHead() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .browser)
        let initialPose = HeadPose(yaw: -12, pitch: 5, roll: 4, timestamp: 1)
        let viewport = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let anchored = try XCTUnwrap(
            store.presentations(for: store.windows, headPose: initialPose)[window.id]
        )
        let anchoredFrame = WindowProjection.frame(
            for: anchored.window.transform,
            in: viewport,
            headPose: anchored.projectionHeadPose
        )

        store.setAttachmentMode(.smoothFollow, for: window.id, headPose: initialPose)
        let initialSmooth = try XCTUnwrap(
            store.presentations(for: store.windows, headPose: initialPose)[window.id]
        )
        let initialSmoothFrame = WindowProjection.frame(
            for: initialSmooth.window.transform,
            in: viewport,
            headPose: initialSmooth.projectionHeadPose
        )

        XCTAssertEqual(initialSmoothFrame.midX, anchoredFrame.midX, accuracy: 0.001)
        XCTAssertEqual(initialSmoothFrame.midY, anchoredFrame.midY, accuracy: 0.001)
        XCTAssertEqual(initialSmooth.projectionHeadPose.yaw, 0, accuracy: 0.001)
        XCTAssertEqual(initialSmooth.projectionHeadPose.pitch, 0, accuracy: 0.001)
        XCTAssertEqual(initialSmooth.projectionHeadPose.roll, 0, accuracy: 0.001)

        let movedPose = HeadPose(yaw: 12, pitch: -5, roll: -4, timestamp: 1.1)
        let moving = try XCTUnwrap(
            store.presentations(for: store.windows, headPose: movedPose)[window.id]
        )
        XCTAssertGreaterThan(moving.projectionHeadPose.yaw, 0)
        XCTAssertLessThan(moving.projectionHeadPose.yaw, movedPose.yaw - initialPose.yaw)
        XCTAssertLessThan(moving.projectionHeadPose.pitch, 0)
        XCTAssertGreaterThan(moving.projectionHeadPose.pitch, movedPose.pitch - initialPose.pitch)

        let settledPose = HeadPose(yaw: 12, pitch: -5, roll: -4, timestamp: 4)
        let settled = try XCTUnwrap(
            store.presentations(for: store.windows, headPose: settledPose)[window.id]
        )
        XCTAssertEqual(settled.projectionHeadPose.yaw, 0, accuracy: 0.01)
        XCTAssertEqual(settled.projectionHeadPose.pitch, 0, accuracy: 0.01)
        XCTAssertEqual(settled.rotationDegrees, 0, accuracy: 0.01)
    }

    func testStackTemporarilyAnchorsFollowWindowsAndRestoresFreeTransform() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .browser)
        let pose = HeadPose(yaw: -9, pitch: 4, roll: 2, timestamp: 1)
        store.setAttachmentMode(.follow, for: window.id, headPose: pose)
        let freeTransform = try XCTUnwrap(store.activeWindow).appTransform

        store.setLayoutMode(.stack, for: pose)
        let stacked = try XCTUnwrap(
            store.presentations(for: store.windows, headPose: pose)[window.id]
        )

        XCTAssertEqual(stacked.projectionHeadPose, pose)
        XCTAssertEqual(stacked.rotationDegrees, -pose.roll)
        XCTAssertEqual(try XCTUnwrap(store.activeWindow).attachmentMode, .follow)
        XCTAssertEqual(try XCTUnwrap(store.activeWindow).appTransform, freeTransform)

        store.setLayoutMode(.freeSpace, for: pose)
        let restored = try XCTUnwrap(
            store.presentations(for: store.windows, headPose: pose)[window.id]
        )
        XCTAssertEqual(restored.projectionHeadPose, .identity)
        XCTAssertEqual(restored.window.appTransform, freeTransform)
    }

    func testStackDragReordersAcrossMultipleIndicesAndMovesWholeRow() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let first = store.addWindow(kind: .browser)
        let second = store.addWindow(kind: .gallery)
        let third = store.addWindow(kind: .remoteDesktop)
        store.focus(first.id)
        store.setLayoutMode(.stack, for: .identity)
        let originalDistance = store.stackTransform.virtualDistance

        store.beginActiveWindowMove()
        let reorderCount = store.moveActiveWindow(normalizedDelta: CGVector(dx: 2.5, dy: 0.25))
        store.endActiveWindowMove()

        XCTAssertEqual(reorderCount, 2)
        XCTAssertEqual(store.stackOrder, [second.id, third.id, first.id])
        XCTAssertEqual(store.stackTransform.pitch, -5.5, accuracy: 0.001)

        store.zoomActiveWindow(by: 1.25)
        XCTAssertEqual(store.stackTransform.virtualDistance, originalDistance / 1.25, accuracy: 0.001)
    }

    func testFreeSpaceDragMovesWindowWithoutChangingStackOrder() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        _ = store.addWindow(kind: .browser)
        let active = store.addWindow(kind: .gallery)
        let originalOrder = store.stackOrder
        let originalYaw = try XCTUnwrap(store.activeWindow).appTransform.yaw

        store.beginActiveWindowMove()
        let reorderCount = store.moveActiveWindow(normalizedDelta: CGVector(dx: 0.25, dy: 0))
        store.endActiveWindowMove()

        XCTAssertEqual(reorderCount, 0)
        XCTAssertEqual(store.stackOrder, originalOrder)
        XCTAssertGreaterThan(
            try XCTUnwrap(store.windows.first(where: { $0.id == active.id })).appTransform.yaw,
            originalYaw
        )
    }

    func testMinimizedStackWindowKeepsItsOrderWithoutLeavingVisibleGap() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let first = store.addWindow(kind: .browser)
        let second = store.addWindow(kind: .gallery)
        let third = store.addWindow(kind: .youtube)
        store.setLayoutMode(.stack, for: .identity)

        store.toggleMinimize(second.id)

        XCTAssertEqual(store.stackOrder, [first.id, second.id, third.id])
        XCTAssertEqual(store.stackPosition(for: first.id)?.index, 0)
        XCTAssertEqual(store.stackPosition(for: third.id)?.index, 1)
        XCTAssertEqual(store.stackPosition(for: third.id)?.count, 2)

        store.close(second.id)
        XCTAssertEqual(store.stackOrder, [first.id, third.id])
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

    func testYouTubeStartsCompactAndCanExpandAfterAuthorization() throws {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = WorkspaceStore(persistence: WorkspacePersistence(container: container))
        let window = store.addWindow(kind: .youtube)

        XCTAssertEqual(store.layout(for: window.id), .youtubeCompact)
        XCTAssertEqual(store.layout(for: window.id)?.panels.count, 1)

        try store.setLayout(.youtube, for: window.id)

        XCTAssertEqual(store.layout(for: window.id)?.panels.count, 4)
    }

    private func makePersistence(
        observeContainer: (ModelContainer) -> Void
    ) throws -> WorkspacePersistence {
        let schema = Schema([WorkspaceSnapshot.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        observeContainer(container)
        return WorkspacePersistence(container: container)
    }
}
