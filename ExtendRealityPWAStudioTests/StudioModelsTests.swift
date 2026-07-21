import CoreGraphics
import XCTest
@testable import ExtendRealityPWAStudio

final class StudioModelsTests: XCTestCase {
    func testLaunchURLAddsAndReplacesDisplayMode() throws {
        let initial = try StudioURL.resolve(
            "http://127.0.0.1:5173/pwa-lab/?foo=bar&extendDisplayMode=widget",
            displayMode: .window
        )
        let components = try XCTUnwrap(URLComponents(url: initial, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.filter { $0.name == "extendDisplayMode" }.count, 1)
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "extendDisplayMode" })?.value,
            "window"
        )
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "foo" })?.value, "bar")
    }

    func testStudioOriginPolicyAllowsOnlySameOrigin() throws {
        let policy = try StudioOriginPolicy(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:5173/pwa-lab/")))
        let sameOrigin = try XCTUnwrap(URL(string: "http://127.0.0.1:5173/pwa-lab/tools"))
        let otherPort = try XCTUnwrap(URL(string: "http://127.0.0.1:5174/pwa-lab/tools"))
        let otherOrigin = try XCTUnwrap(URL(string: "https://example.com/"))
        XCTAssertTrue(policy.allows(sameOrigin))
        XCTAssertFalse(policy.allows(otherPort))
        XCTAssertFalse(policy.allows(otherOrigin))
    }

    func testBundledLaunchURLUsesEmbeddedOriginAndAddsDisplayMode() throws {
        let initial = try StudioURL.resolve(
            StudioPreset.spatialVideo.defaultAddress,
            displayMode: .widget
        )
        XCTAssertEqual(initial.scheme, BundledPWAResources.scheme)
        XCTAssertEqual(initial.host, BundledPWAResources.host)
        XCTAssertEqual(
            URLComponents(url: initial, resolvingAgainstBaseURL: false)?.path,
            "/spatial-video/"
        )
        XCTAssertTrue(initial.hasDirectoryPath)
        XCTAssertEqual(
            URLComponents(url: initial, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "extendDisplayMode" })?.value,
            "widget"
        )
    }

    func testBundledOriginPolicyAllowsOnlyBundledHost() throws {
        let baseURL = try XCTUnwrap(URL(string: StudioPreset.pwaLab.defaultAddress))
        let policy = try StudioOriginPolicy(baseURL: baseURL)
        XCTAssertTrue(policy.allows(BundledPWAResources.appURL(path: "pwa-lab/tools")))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "extendreality-pwa://other/pwa-lab/"))))
        XCTAssertFalse(policy.allows(try XCTUnwrap(URL(string: "https://example.com/"))))
    }

    @MainActor
    func testBundledResourceHandlerResolvesIndexAndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pwa-bundle-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let appDirectory = root.appending(path: "pwa-lab", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = appDirectory.appending(path: "index.html")
        try Data("<!doctype html>".utf8).write(to: indexURL)

        let handler = BundledPWAResourceHandler(resourceRoot: root)
        XCTAssertEqual(
            try handler.resourceURL(for: BundledPWAResources.appURL(path: "pwa-lab")),
            indexURL.standardizedFileURL
        )
        XCTAssertThrowsError(
            try handler.resourceURL(
                for: XCTUnwrap(URL(string: "extendreality-pwa://bundled/%2E%2E/secret.txt"))
            )
        )
    }

    func testBundledHTTPServerUsesLoopbackOriginAndReferrerPolicy() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "pwa-http-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let appDirectory = root.appending(path: "spatial-video", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Data("<!doctype html><title>Spatial Video</title>".utf8)
        try expected.write(to: appDirectory.appending(path: "index.html"))

        let server = try BundledPWAHTTPServer(resourceRoot: root)
        let url = try await server.appURL(path: "spatial-video")
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertTrue(url.hasDirectoryPath)
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(httpResponse.value(forHTTPHeaderField: "Referrer-Policy"), "strict-origin-when-cross-origin")
        XCTAssertEqual(data, expected)
    }

    func testProjectionRespondsToYawDistanceAndScale() {
        let layout = SpatialAppLayout(panels: [
            SpatialPanelDescriptor(
                id: .primary,
                accessibilityLabel: "Primary",
                placement: SpatialPanelPlacement(width: 0.5, height: 0.4),
                content: .primary
            )
        ])
        let viewport = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        let centered = StudioProjection.project(
            layout: layout,
            transform: StudioWindowTransform(),
            in: viewport
        )[0].frame
        let transformed = StudioProjection.project(
            layout: layout,
            transform: StudioWindowTransform(yaw: 12, pitch: 0, distance: 1.5, scale: 1.2),
            in: viewport
        )[0].frame

        XCTAssertGreaterThan(transformed.midX, centered.midX)
        XCTAssertLessThan(transformed.width, centered.width * 1.2)
    }

    func testProjectionRespondsToVirtualCameraRotation() {
        let layout = SpatialAppLayout(panels: [
            SpatialPanelDescriptor(
                id: .primary,
                accessibilityLabel: "Primary",
                placement: SpatialPanelPlacement(width: 0.5, height: 0.4),
                content: .primary
            )
        ])
        let viewport = CGRect(x: 0, y: 0, width: 1_000, height: 600)
        let forward = StudioProjection.project(
            layout: layout,
            transform: StudioWindowTransform(),
            in: viewport
        )[0].frame
        let lookingRight = StudioProjection.project(
            layout: layout,
            transform: StudioWindowTransform(),
            camera: StudioCameraTransform(yaw: 12),
            in: viewport
        )[0].frame

        XCTAssertLessThan(lookingRight.midX, forward.midX)
    }

    func testFixturePayloadMatchesHostContract() throws {
        let fixtures = StudioFixtureData()
        let location = try fixtures.payload(for: .location)
        let health = try fixtures.payload(for: .health)
        let focus = try fixtures.payload(for: .focusStatus)

        XCTAssertNotNil(location["latitude"])
        XCTAssertNotNil(health["steps"])
        XCTAssertNotNil(focus["isFocused"])
    }

    func testProjectCommandQuotesDirectoryAndPreservesCommand() {
        let directory = URL(fileURLWithPath: "/tmp/O'Brien PWA")
        XCTAssertEqual(
            StudioProjectCommand.fullCommand(directory: directory, command: "npm run dev"),
            "cd '/tmp/O'\\''Brien PWA' && npm run dev"
        )
    }

    func testProjectCommandRejectsWhitespaceOnlyCommand() {
        XCTAssertEqual(
            StudioProjectCommand.fullCommand(
                directory: URL(fileURLWithPath: "/tmp/PWA"),
                command: "  \n "
            ),
            ""
        )
    }

    @MainActor
    func testProjectInspectionReadsPackageScriptsAndIndex() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pwa-studio-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"name":"sample-pwa","scripts":{"dev":"vite","build":"vite build"}}"#.utf8)
            .write(to: directory.appending(path: "package.json"))
        try Data("<!doctype html>".utf8)
            .write(to: directory.appending(path: "index.html"))

        let access = StudioProjectAccess(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "pwa-studio-tests-\(UUID().uuidString)"))
        )
        let inspection = try access.inspect(directory)

        XCTAssertEqual(inspection.packageName, "sample-pwa")
        XCTAssertEqual(inspection.scripts.map(\.name), ["build", "dev"])
        XCTAssertTrue(inspection.containsIndexHTML)
    }

    @MainActor
    func testProjectInspectionReportsMalformedPackageWithStageAndSystemDetails() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "pwa-studio-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"scripts": ["dev"]}"#.utf8)
            .write(to: directory.appending(path: "package.json"))

        let access = StudioProjectAccess(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "pwa-studio-tests-\(UUID().uuidString)"))
        )

        XCTAssertThrowsError(try access.inspect(directory)) { error in
            guard let failure = error as? StudioProjectAccessFailure else {
                return XCTFail("Expected StudioProjectAccessFailure, got \(error)")
            }
            XCTAssertEqual(failure.operation, .decodePackageManifest)
            XCTAssertTrue(failure.diagnostics.contains("Operation: Parse package.json"))
            XCTAssertTrue(failure.diagnostics.contains("package.json"))
            XCTAssertTrue(failure.diagnostics.contains("System error:"))

            let issue = StudioProjectIssue(error: failure)
            XCTAssertEqual(issue.title, "Couldn’t parse package.json.")
            XCTAssertFalse(issue.diagnostics.isEmpty)
        }
    }

    func testGenericBookmarkErrorGetsActionableContext() {
        let systemError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadUnknownError,
            userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be opened."]
        )
        let directory = URL(fileURLWithPath: "/Volumes/Cloud/PWA")
        let failure = StudioProjectAccessFailure(
            operation: .saveBookmark,
            url: directory,
            underlyingError: systemError
        )
        let issue = StudioProjectIssue(error: failure)

        XCTAssertEqual(issue.title, "Couldn’t remember access to “PWA”.")
        XCTAssertEqual(
            issue.reason,
            "macOS couldn’t create a persistent, read-only security bookmark for this directory."
        )
        XCTAssertTrue(issue.diagnostics.contains("Operation: Save directory access"))
        XCTAssertTrue(issue.diagnostics.contains("Path: /Volumes/Cloud/PWA"))
        XCTAssertTrue(issue.diagnostics.contains("System error: NSCocoaErrorDomain"))
        XCTAssertTrue(issue.diagnostics.contains("The file couldn’t be opened."))
    }
}
