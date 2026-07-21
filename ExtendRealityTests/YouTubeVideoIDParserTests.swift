import XCTest
@testable import ExtendReality

final class YouTubeVideoIDParserTests: XCTestCase {
    func testParsesSupportedYouTubeURLs() {
        XCTAssertEqual(YouTubeVideoIDParser.parse("dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(
            YouTubeVideoIDParser.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
        XCTAssertEqual(
            YouTubeVideoIDParser.parse("https://youtu.be/dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
        XCTAssertEqual(
            YouTubeVideoIDParser.parse("https://www.youtube.com/shorts/dQw4w9WgXcQ"),
            "dQw4w9WgXcQ"
        )
    }

    func testRejectsUnrelatedURL() {
        XCTAssertNil(YouTubeVideoIDParser.parse("https://example.com/video"))
    }

    func testPlayerIdentityUsesNormalizedAppBundleIdentifier() {
        XCTAssertEqual(
            YouTubePlayerClientIdentity.origin(appIdentifier: "com.Example.VideoApp").absoluteString,
            "https://com.example.videoapp/"
        )
        XCTAssertEqual(
            YouTubePlayerClientIdentity.origin(appIdentifier: nil).absoluteString,
            "https://com.vladprusakov.extendreality/"
        )
    }
}

@MainActor
final class YouTubeSessionStateTests: XCTestCase {
    func testPlayerTelemetryUpdatesSharedPlaybackState() {
        let session = YouTubeSession(initialVideoID: nil, loadsContent: false)

        session.receivePlayerState([
            "ready": true,
            "state": 1,
            "time": 42.5,
            "duration": 180.0,
        ])

        XCTAssertTrue(session.isReady)
        XCTAssertTrue(session.isPlaying)
        XCTAssertEqual(session.currentTime, 42.5)
        XCTAssertEqual(session.duration, 180)
    }

    func testSearchPanelKeyboardInputUsesSharedQuery() {
        let session = YouTubeSession(initialVideoID: nil, loadsContent: false)

        session.handle(.insertText("spatial computing"), in: "search")

        XCTAssertEqual(session.query, "spatial computing")
    }

    func testSearchPanelFieldRequestsKeyboardFocus() {
        var focusRequestCount = 0
        let session = YouTubeSession(
            initialVideoID: nil,
            loadsContent: false,
            textInputFocusHandler: { focusRequestCount += 1 }
        )

        session.handle(
            .pointerUp(normalizedPosition: CGPoint(x: 0.5, y: 0.1)),
            in: "search"
        )

        XCTAssertEqual(focusRequestCount, 1)
    }

    func testPlayerErrorReportsMissingClientIdentity() {
        let session = YouTubeSession(initialVideoID: nil, loadsContent: false)

        session.receivePlayerState(["error": 153])

        XCTAssertFalse(session.isReady)
        XCTAssertFalse(session.isPlaying)
        XCTAssertEqual(
            session.playerErrorMessage,
            "YouTube rejected the app identity. Update ExtendReality and try again."
        )
    }
}
