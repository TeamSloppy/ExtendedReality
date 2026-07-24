import Foundation
import XCTest
@testable import ExtendReality

final class YouTubeAPIClientTests: XCTestCase {
    override func tearDown() {
        YouTubeURLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func testOAuthSearchUsesBearerTokenAndDecodesVideos() async throws {
        YouTubeURLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
            XCTAssertEqual(request.url?.path, "/youtube/v3/search")
            XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "key" }))
            return Self.response(
                for: request,
                json: """
                {"items":[{"id":{"videoId":"dQw4w9WgXcQ"},"snippet":{"title":"Test &amp; Video","channelTitle":"Channel","thumbnails":{"medium":{"url":"https://example.com/video.jpg"}}}}]}
                """
            )
        }

        let videos = try await makeClient().search(query: "test", accessToken: "oauth-token")

        XCTAssertEqual(videos.first?.id, "dQw4w9WgXcQ")
        XCTAssertEqual(videos.first?.title, "Test & Video")
        XCTAssertEqual(videos.first?.channelTitle, "Channel")
    }

    func testOAuthSearchPreservesCyrillicWhileDecodingHTMLEntities() async throws {
        YouTubeURLProtocolStub.requestHandler = { request in
            Self.response(
                for: request,
                json: """
                {"items":[{"id":{"videoId":"dQw4w9WgXcQ"},"snippet":{"title":"Кириллица &amp; emoji 🚀","channelTitle":"Канал","thumbnails":{}}}]}
                """
            )
        }

        let videos = try await makeClient().search(
            query: "кириллица",
            accessToken: "oauth-token"
        )

        XCTAssertEqual(videos.first?.title, "Кириллица & emoji 🚀")
        XCTAssertEqual(videos.first?.channelTitle, "Канал")
    }

    func testPlaylistBuildsYouTubeUniversalLink() {
        let playlist = YouTubePlaylist(
            id: "PL-flight_123",
            title: "Flight",
            itemCount: 8,
            thumbnailURL: nil
        )

        XCTAssertEqual(
            playlist.youtubeURL.absoluteString,
            "https://www.youtube.com/playlist?list=PL-flight_123"
        )
    }

    func testOAuthLibraryEndpointsDecodeSubscriptionsLikesAndPlaylists() async throws {
        YouTubeURLProtocolStub.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-token")
            switch request.url?.path {
            case "/youtube/v3/subscriptions":
                return Self.response(
                    for: request,
                    json: """
                    {"items":[{"id":"subscription-id","snippet":{"title":"Subscribed Channel","channelTitle":"Subscribed Channel","resourceId":{"channelId":"channel-id"},"thumbnails":{"default":{"url":"https://example.com/channel.jpg"}}}}]}
                    """
                )
            case "/youtube/v3/videos":
                return Self.response(
                    for: request,
                    json: """
                    {"items":[{"id":"liked-video","snippet":{"title":"Liked Video","channelTitle":"Creator","thumbnails":{"default":{"url":"https://example.com/liked.jpg"}}}}]}
                    """
                )
            case "/youtube/v3/playlists":
                return Self.response(
                    for: request,
                    json: """
                    {"items":[{"id":"playlist-id","snippet":{"title":"Watch Later","channelTitle":"Owner","thumbnails":{"default":{"url":"https://example.com/playlist.jpg"}}},"contentDetails":{"itemCount":12}}]}
                    """
                )
            default:
                XCTFail("Unexpected endpoint: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, statusCode: 404, json: "{}")
            }
        }
        let client = makeClient()

        let subscriptions = try await client.subscriptions(accessToken: "oauth-token")
        let liked = try await client.likedVideos(accessToken: "oauth-token")
        let playlists = try await client.playlists(accessToken: "oauth-token")

        XCTAssertEqual(subscriptions.first?.channelID, "channel-id")
        XCTAssertEqual(liked.first?.id, "liked-video")
        XCTAssertEqual(playlists.first?.itemCount, 12)
    }

    func testAccountLibraryChannelErrorSuggestsSwitchingAccounts() async {
        YouTubeURLProtocolStub.requestHandler = { request in
            Self.response(
                for: request,
                statusCode: 404,
                json: """
                {
                  "error": {
                    "message": "Channel not found.",
                    "errors": [{"reason": "channelNotFound"}]
                  }
                }
                """
            )
        }

        do {
            _ = try await makeClient().subscriptions(accessToken: "oauth-token")
            XCTFail("Expected the request to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "This Google account has no available YouTube channel. Switch accounts or create a YouTube channel, then try again."
            )
        }
    }

    private func makeClient() -> YouTubeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [YouTubeURLProtocolStub.self]
        return YouTubeAPIClient(session: URLSession(configuration: configuration))
    }

    private static func response(
        for request: URLRequest,
        statusCode: Int = 200,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private final class YouTubeURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.requestHandler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
