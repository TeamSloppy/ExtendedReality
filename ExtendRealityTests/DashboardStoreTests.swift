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
        XCTAssertTrue(store.launchers.contains(where: { $0.content == .app(.maps) }))
        XCTAssertEqual(store.widgets.count, 4)
        XCTAssertTrue(store.widgets.contains(where: { $0.content == .widget(.translation) }))
    }

    func testDashboardApplicationsContainOnlyNativeAppsAndPWAs() {
        let store = DashboardStore(defaults: makeDefaults(), storageKey: #function)

        XCTAssertFalse(store.applications.isEmpty)
        XCTAssertTrue(store.applications.allSatisfy { item in
            switch item.content {
            case .app, .pwa: true
            case .bookmark, .widget: false
            }
        })
    }

    func testDashboardApplicationProjectionUsesCenteredFiveColumnGrid() {
        let store = DashboardStore(defaults: makeDefaults(), storageKey: #function)
        let canvasSize = CGSize(width: 1_920, height: 1_080)

        let presentations = DashboardApplicationProjection.presentations(
            for: store.launchers,
            in: canvasSize
        )

        XCTAssertEqual(presentations.count, store.launchers.count)
        XCTAssertTrue(presentations.allSatisfy { $0.rotationDegrees == 0 })
        XCTAssertEqual(Set(presentations.map(\.center)).count, presentations.count)
        XCTAssertTrue(presentations.allSatisfy { presentation in
            CGRect(origin: .zero, size: canvasSize).contains(presentation.center)
                && presentation.size.width > 0
                && presentation.size.height > 0
        })

        let firstRow = Array(presentations.prefix(DashboardApplicationProjection.maximumColumnCount))
        XCTAssertEqual(firstRow.map(\.center.y), Array(repeating: firstRow[0].center.y, count: firstRow.count))
        XCTAssertEqual(firstRow.map(\.center.x), firstRow.map(\.center.x).sorted())
        XCTAssertGreaterThan(firstRow[0].center.y, canvasSize.height * 0.4)
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

    func testArbitraryLauncherCountReceivesPersistedPlacements() {
        let store = DashboardStore(defaults: makeDefaults(), storageKey: #function)

        for index in 0 ..< 25 {
            XCTAssertTrue(store.addBookmark(title: "Site \(index)", url: "site\(index).example.com"))
        }

        XCTAssertEqual(store.launchers.count, 34)
        XCTAssertTrue(store.launchers.allSatisfy(\.placement.isPlaced))
    }

    func testMoveScaleAndLayerAreClampedAndPersisted() throws {
        let defaults = makeDefaults()
        let key = #function
        let store = DashboardStore(defaults: defaults, storageKey: key)
        let item = try XCTUnwrap(store.widgets.first)
        let previousTopLayer = try XCTUnwrap(store.items.map(\.placement.zIndex).max())

        store.beginArranging(item.id)
        store.moveSelected(normalizedDelta: CGVector(dx: -10, dy: -10))
        store.scaleSelected(by: 100)
        store.endArranging()

        let moved = try XCTUnwrap(store.item(id: item.id))
        XCTAssertEqual(moved.placement.scale, DashboardPlacement.scaleRange.upperBound)
        XCTAssertGreaterThan(moved.placement.x, 0)
        XCTAssertGreaterThan(moved.placement.y, DashboardLayout.reservedTopFraction)
        XCTAssertGreaterThan(moved.placement.zIndex, previousTopLayer)

        let restored = DashboardStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(restored.item(id: item.id)?.placement, moved.placement)
    }

    func testLegacyItemsWithoutPlacementAreMigrated() throws {
        struct LegacyItem: Codable {
            let id: UUID
            let content: DashboardItemContent
        }

        let defaults = makeDefaults()
        let key = #function
        let id = UUID()
        defaults.set(
            try JSONEncoder().encode([LegacyItem(id: id, content: .widget(.health))]),
            forKey: key
        )

        let store = DashboardStore(defaults: defaults, storageKey: key)

        XCTAssertTrue(try XCTUnwrap(store.item(id: id)).placement.isPlaced)
        let persisted = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertNotNil(String(data: persisted, encoding: .utf8)?.range(of: "placement"))
    }

    func testResetLayoutPreservesItemsAndRestoresDefaultPlacement() throws {
        let store = DashboardStore(defaults: makeDefaults(), storageKey: #function)
        let item = try XCTUnwrap(store.widgets.first)
        store.beginArranging(item.id)
        store.moveSelected(normalizedDelta: CGVector(dx: 0.2, dy: 0.2))
        store.endArranging()

        store.resetLayout()

        XCTAssertEqual(store.items.count, 13)
        XCTAssertNotEqual(store.item(id: item.id)?.placement.zIndex, -1)
    }

    func testScenariosKeepIndependentWidgetSetsAndPlacements() throws {
        let defaults = makeDefaults()
        let key = #function
        let store = DashboardStore(defaults: defaults, storageKey: key)

        store.selectScenario(.personal)
        store.addWidget(.focus)
        let personalFocus = try XCTUnwrap(
            store.widgets.first(where: { $0.content == .widget(.focus) })
        )
        store.beginArranging(personalFocus.id)
        store.moveSelected(normalizedDelta: CGVector(dx: 0.18, dy: 0.12))
        store.endArranging()
        let personalPlacement = try XCTUnwrap(store.item(id: personalFocus.id)?.placement)

        store.selectScenario(.work)
        store.toggleWidget(.focus)
        XCTAssertFalse(store.containsWidget(.focus))

        store.selectScenario(.personal)
        XCTAssertTrue(store.containsWidget(.focus))
        XCTAssertEqual(store.item(id: personalFocus.id)?.placement, personalPlacement)

        let restored = DashboardStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(restored.activeScenario, .personal)
        XCTAssertTrue(restored.containsWidget(.focus))
        XCTAssertEqual(restored.item(id: personalFocus.id)?.placement, personalPlacement)
    }

    func testLegacyWidgetsMigrateIntoWorkScenario() throws {
        let defaults = makeDefaults()
        let key = #function
        let legacyItems = [
            DashboardItem(content: .app(.browser)),
            DashboardItem(content: .widget(.health)),
        ]
        defaults.set(try JSONEncoder().encode(legacyItems), forKey: key)

        let migrated = DashboardStore(defaults: defaults, storageKey: key)

        XCTAssertEqual(migrated.activeScenario, .work)
        XCTAssertTrue(migrated.containsWidget(.health))
        migrated.selectScenario(.personal)
        migrated.toggleWidget(.health)
        XCTAssertFalse(migrated.containsWidget(.health))
        migrated.selectScenario(.work)
        XCTAssertTrue(migrated.containsWidget(.health))
    }

    func testDashboardProjectionUsesOnlyRollForStabilization() throws {
        let item = DashboardItem(
            content: .widget(.focus),
            placement: DashboardPlacement(x: 0.25, y: 0.5, scale: 1, zIndex: 0)
        )
        let firstPose = HeadPose(yaw: 0, pitch: 0, roll: 12, timestamp: 1)
        let secondPose = HeadPose(yaw: 40, pitch: -20, roll: 12, timestamp: 2)
        let firstRotation = DashboardProjection.stabilizationRotation(for: firstPose, isTracking: true)
        let secondRotation = DashboardProjection.stabilizationRotation(for: secondPose, isTracking: true)

        XCTAssertEqual(firstRotation, -12)
        XCTAssertEqual(secondRotation, firstRotation)
        XCTAssertEqual(
            DashboardProjection.presentation(
                for: item,
                in: CGSize(width: 1_920, height: 1_080),
                rotationDegrees: firstRotation
            ),
            DashboardProjection.presentation(
                for: item,
                in: CGSize(width: 1_920, height: 1_080),
                rotationDegrees: secondRotation
            )
        )
        XCTAssertEqual(
            DashboardProjection.stabilizationRotation(for: firstPose, isTracking: false),
            0
        )
    }

    func testPWAIsAddedOnceAndPersistsOnDashboard() throws {
        let defaults = makeDefaults()
        let key = #function
        let store = DashboardStore(defaults: defaults, storageKey: key)
        let manifest = PWAAppManifest(
            id: "com.example.tasks",
            name: "Tasks",
            summary: "Task manager",
            developer: "Example",
            version: "1.0.0",
            launchURL: URL(string: "https://tasks.example.com")!,
            universalLink: URL(string: "https://tasks.example.com/apps/tasks")!,
            allowedOrigins: ["https://tasks.example.com"],
            displayModes: [.window],
            requestedCapabilities: [],
            minimumAge: 4,
            accentHex: "#2563EB"
        )
        let installation = PWAInstallation(
            manifest: manifest,
            installedAt: .now,
            dataStoreIdentifier: UUID(),
            grantedCapabilities: []
        )

        store.addPWA(installation)
        store.addPWA(installation)
        let restored = DashboardStore(defaults: defaults, storageKey: key)
        let matches = restored.launchers.filter {
            if case .pwa(let app) = $0.content { return app.id == installation.id }
            return false
        }

        XCTAssertEqual(matches.count, 1)
    }

    func testExistingDashboardReceivesMapsLauncherOnlyOnce() throws {
        let defaults = makeDefaults()
        let key = #function
        let legacyItems = [DashboardItem(content: .app(.browser))]
        defaults.set(try JSONEncoder().encode(legacyItems), forKey: key)

        let migrated = DashboardStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(migrated.items.filter { $0.content == .app(.maps) }.count, 1)

        let mapsIndex = try XCTUnwrap(migrated.items.firstIndex(where: { $0.content == .app(.maps) }))
        migrated.remove(at: IndexSet(integer: mapsIndex))
        let restored = DashboardStore(defaults: defaults, storageKey: key)

        XCTAssertFalse(restored.items.contains(where: { $0.content == .app(.maps) }))
    }

    func testExistingDashboardReceivesTranslationWidgetOnlyOnce() throws {
        let defaults = makeDefaults()
        let key = #function
        let legacyItems = [DashboardItem(content: .widget(.calendar))]
        defaults.set(try JSONEncoder().encode(legacyItems), forKey: key)

        let migrated = DashboardStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(migrated.items.filter { $0.content == .widget(.translation) }.count, 1)

        let translationIndex = try XCTUnwrap(
            migrated.items.firstIndex(where: { $0.content == .widget(.translation) })
        )
        migrated.remove(at: IndexSet(integer: translationIndex))
        let restored = DashboardStore(defaults: defaults, storageKey: key)

        XCTAssertFalse(restored.items.contains(where: { $0.content == .widget(.translation) }))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "DashboardStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
