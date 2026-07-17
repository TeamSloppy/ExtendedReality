import XCTest
@testable import ExtendReality

final class MacStreamProtocolTests: XCTestCase {
    func testDecodesRemoteStartResponse() throws {
        let data = Data(
            """
            {
              "version": 1,
              "layout": "multiple",
              "streams": [
                {"id":"1","name":"Studio Display","url":"http://mac.local:52799/display/1"},
                {"id":"2","name":"Built-in Display","url":"http://mac.local:52799/display/2"}
              ]
            }
            """.utf8
        )

        let session = try JSONDecoder().decode(MacStreamSession.self, from: data)

        XCTAssertEqual(session.version, 1)
        XCTAssertEqual(session.layout, .multiple)
        XCTAssertEqual(session.streams.map(\.name), ["Studio Display", "Built-in Display"])
        XCTAssertEqual(session.streams.last?.url.path, "/display/2")
    }

    func testRecognizesOnlyHTTPMacStreamAddresses() {
        XCTAssertTrue(SurfaceRegistry.isWebStreamAddress("http://mac.local:52799/"))
        XCTAssertTrue(SurfaceRegistry.isWebStreamAddress("https://mac.local/"))
        XCTAssertFalse(SurfaceRegistry.isWebStreamAddress("mac.local"))
        XCTAssertFalse(SurfaceRegistry.isWebStreamAddress(nil))
    }
}
