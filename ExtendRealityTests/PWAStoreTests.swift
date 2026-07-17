import Foundation
import XCTest
@testable import ExtendReality

@MainActor
final class PWAStoreTests: XCTestCase {
    func testCatalogValidationRequiresSecureAllowedLaunchOrigin() throws {
        let valid = makeManifest()
        XCTAssertNoThrow(try valid.validate())

        let invalid = makeManifest(
            launchURL: URL(string: "http://notes.example.com/app")!,
            allowedOrigins: ["https://notes.example.com"]
        )
        XCTAssertThrowsError(try invalid.validate()) { error in
            XCTAssertEqual(error as? PWAValidationError, .insecureURL(invalid.id))
        }
    }

    func testOriginPolicyAllowsOnlyCatalogOrigins() throws {
        let policy = try PWAOriginPolicy(manifest: makeManifest())

        XCTAssertTrue(policy.allowsTopLevelNavigation(to: URL(string: "https://notes.example.com/editor/1")!))
        XCTAssertFalse(policy.allowsTopLevelNavigation(to: URL(string: "https://tracker.example.net/")!))
        XCTAssertFalse(policy.allowsTopLevelNavigation(to: URL(string: "http://notes.example.com/")!))
    }

    func testInstallationPersistsCapabilitiesAndDataStoreIdentity() throws {
        let defaults = makeDefaults()
        let storageKey = "installations.\(#function)"
        let ageKey = "age.\(#function)"
        let store = PWAStore(
            defaults: defaults,
            storageKey: storageKey,
            declaredAgeKey: ageKey,
            catalogURL: nil
        )
        store.setDeclaredAge(18)

        let installed = try store.install(makeManifest(), grantedCapabilities: [.camera, .location, .health, .focusStatus])
        let restored = PWAStore(
            defaults: defaults,
            storageKey: storageKey,
            declaredAgeKey: ageKey,
            catalogURL: nil
        )

        XCTAssertEqual(restored.installation(for: installed.id), installed)
        XCTAssertEqual(restored.declaredAge, 18)
        XCTAssertTrue(try XCTUnwrap(restored.installation(for: installed.id)).grants(.camera))
        XCTAssertTrue(try XCTUnwrap(restored.installation(for: installed.id)).grants(.location))
        XCTAssertTrue(try XCTUnwrap(restored.installation(for: installed.id)).grants(.health))
        XCTAssertTrue(try XCTUnwrap(restored.installation(for: installed.id)).grants(.focusStatus))
        XCTAssertFalse(try XCTUnwrap(restored.installation(for: installed.id)).grants(.microphone))
    }

    func testAgeRestrictedAppCannotBeInstalledWithoutDeclaredAge() {
        let store = PWAStore(
            defaults: makeDefaults(),
            storageKey: #function,
            declaredAgeKey: "age.\(#function)",
            catalogURL: nil
        )
        let manifest = makeManifest(minimumAge: 16)

        XCTAssertThrowsError(try store.install(manifest, grantedCapabilities: [])) { error in
            XCTAssertEqual(
                error as? PWAValidationError,
                .ageRestricted(manifest.id, requiredAge: 16)
            )
        }
    }

    func testRefreshLoadsValidatedCatalog() async throws {
        let document = PWACatalogDocument(schemaVersion: 1, apps: [makeManifest()])
        let data = try JSONEncoder().encode(document)
        let store = PWAStore(
            defaults: makeDefaults(),
            storageKey: #function,
            declaredAgeKey: "age.\(#function)",
            catalogURL: URL(string: "https://catalog.example.com/v1.json"),
            client: PWACatalogClient { _ in data }
        )

        await store.refresh()

        XCTAssertEqual(store.catalog, document.apps)
        guard case .loaded = store.catalogState else {
            return XCTFail("Expected loaded catalog state")
        }
    }

    private func makeManifest(
        launchURL: URL = URL(string: "https://notes.example.com/app")!,
        allowedOrigins: [String] = ["https://notes.example.com"],
        minimumAge: Int = 4
    ) -> PWAAppManifest {
        PWAAppManifest(
            id: "com.example.notes",
            name: "Notes",
            summary: "Offline notes",
            developer: "Example",
            version: "1.0.0",
            launchURL: launchURL,
            universalLink: URL(string: "https://notes.example.com/apps/notes")!,
            allowedOrigins: allowedOrigins,
            displayModes: [.window, .widget],
            requestedCapabilities: [.camera, .microphone, .location, .health, .focusStatus],
            minimumAge: minimumAge,
            accentHex: "#2563EB"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "PWAStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
