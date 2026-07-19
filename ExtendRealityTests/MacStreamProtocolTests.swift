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
                {"id":"1","name":"Studio Display","url":"http://mac.local:52799/display/1","width":2560,"height":1440},
                {"id":"2","name":"Built-in Display","url":"http://mac.local:52799/display/2","width":1728,"height":1116}
              ]
            }
            """.utf8
        )

        let session = try JSONDecoder().decode(MacStreamSession.self, from: data)

        XCTAssertEqual(session.version, 1)
        XCTAssertEqual(session.layout, .multiple)
        XCTAssertEqual(session.streams.map(\.name), ["Studio Display", "Built-in Display"])
        XCTAssertEqual(session.streams.last?.url.path, "/display/2")
        XCTAssertEqual(try XCTUnwrap(session.streams.first?.aspectRatio), 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertNil(session.cursorURL)
    }

    func testDecodesVirtualCursorChannel() throws {
        let sessionData = Data(
            """
            {
              "version": 1,
              "layout": "single",
              "streams": [
                {"id":"primary","name":"Mac","url":"http://mac.local:52799/","width":2560,"height":1440}
              ],
              "cursorURL": "http://mac.local:52799/api/v1/cursor"
            }
            """.utf8
        )
        let cursorData = Data(
            """
            {"version":1,"streamID":"primary","x":0.25,"y":0.75,"visible":true}
            """.utf8
        )

        let session = try JSONDecoder().decode(MacStreamSession.self, from: sessionData)
        let cursor = try JSONDecoder().decode(MacCursorPosition.self, from: cursorData)

        XCTAssertEqual(session.cursorURL?.path, "/api/v1/cursor")
        XCTAssertEqual(cursor.streamID, "primary")
        XCTAssertEqual(cursor.x, 0.25)
        XCTAssertEqual(cursor.y, 0.75)
        XCTAssertTrue(cursor.visible)
    }

    func testRecognizesOnlyHTTPMacStreamAddresses() {
        XCTAssertTrue(SurfaceRegistry.isWebStreamAddress("http://mac.local:52799/"))
        XCTAssertTrue(SurfaceRegistry.isWebStreamAddress("https://mac.local/"))
        XCTAssertFalse(SurfaceRegistry.isWebStreamAddress("mac.local"))
        XCTAssertFalse(SurfaceRegistry.isWebStreamAddress(nil))
    }
}
