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
}

