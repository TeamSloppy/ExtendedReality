import XCTest
@testable import ExtendReality

final class MapsRouteLinkTests: XCTestCase {
    func testParsesUnifiedDirectionsLink() throws {
        let url = try XCTUnwrap(
            URL(string: "https://maps.apple.com/directions?source=37.795442,-122.393624&destination=San%20Francisco%20City%20Hall&mode=walking")
        )

        let route = try XCTUnwrap(AppleMapsRouteLink.parse(url))

        XCTAssertEqual(route.source, "37.795442,-122.393624")
        XCTAssertEqual(route.destination, "San Francisco City Hall")
        XCTAssertEqual(route.transport, .walking)
    }

    func testParsesLegacyDirectionsLink() throws {
        let url = try XCTUnwrap(
            URL(string: "https://maps.apple.com/?saddr=Current%20Location&daddr=Apple%20Park&dirflg=d")
        )

        let route = try XCTUnwrap(AppleMapsRouteLink.parse(url))

        XCTAssertEqual(route.source, "Current Location")
        XCTAssertEqual(route.destination, "Apple Park")
        XCTAssertEqual(route.transport, .driving)
    }

    func testPlaceLinkBecomesDestination() throws {
        let url = try XCTUnwrap(
            URL(string: "https://maps.apple.com/place?name=Apple%20Park&coordinate=37.3349,-122.0090")
        )

        let route = try XCTUnwrap(AppleMapsRouteLink.parse(url))

        XCTAssertNil(route.source)
        XCTAssertEqual(route.destination, "Apple Park")
    }

    func testParsesCyclingMode() throws {
        let url = try XCTUnwrap(
            URL(string: "https://maps.apple.com/directions?destination=Apple%20Park&mode=cycling")
        )
        XCTAssertEqual(AppleMapsRouteLink.parse(url)?.transport, .cycling)
    }

    func testRejectsNonAppleMapsURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/directions?destination=Apple%20Park"))
        XCTAssertNil(AppleMapsRouteLink.parse(url))
    }
}
