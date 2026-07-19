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
