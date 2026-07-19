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
}
