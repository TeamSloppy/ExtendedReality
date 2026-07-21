import XCTest
@testable import ExtendReality

final class MacStreamProtocolTests: XCTestCase {
    func testDecodesShareableApplicationCatalog() throws {
        let data = Data(
            """
            {
              "version": 1,
              "applications": [
                {
                  "id": "pid:321",
                  "name": "Preview",
                  "bundleIdentifier": "com.apple.Preview",
                  "processID": 321
                }
              ]
            }
            """.utf8
        )

        let catalog = try JSONDecoder().decode(MacShareableApplicationCatalog.self, from: data)

        XCTAssertEqual(catalog.version, 1)
        XCTAssertEqual(catalog.applications.first?.id, "pid:321")
        XCTAssertEqual(catalog.applications.first?.name, "Preview")
    }

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
        XCTAssertNil(session.audio)
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
              "cursorURL": "http://mac.local:52799/api/v1/cursor",
              "audio": {
                "version": 1,
                "playbackURL": "http://mac.local:52799/api/v1/audio/playback.pcm",
                "microphoneURL": "http://mac.local:52799/api/v1/audio/microphone.pcm",
                "sampleRate": 48000,
                "playbackChannels": 2,
                "microphoneChannels": 1
              }
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
        XCTAssertTrue(try XCTUnwrap(session.audio).isSupported)
        XCTAssertEqual(session.audio?.playbackURL.path, "/api/v1/audio/playback.pcm")
    }

    func testRecognizesOnlyHTTPMacStreamAddresses() {
        XCTAssertTrue(SurfaceRegistry.isWebStreamAddress("http://mac.local:52799/"))
        XCTAssertTrue(SurfaceRegistry.isWebStreamAddress("https://mac.local/"))
        XCTAssertFalse(SurfaceRegistry.isWebStreamAddress("mac.local"))
        XCTAssertFalse(SurfaceRegistry.isWebStreamAddress(nil))
    }
}
