import Foundation

struct YouTubeVideo: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let channelTitle: String
    let thumbnailURL: URL?
}

struct YouTubeSubscription: Identifiable, Equatable, Sendable {
    let id: String
    let channelID: String
    let title: String
    let thumbnailURL: URL?
}

struct YouTubePlaylist: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let itemCount: Int
    let thumbnailURL: URL?

    var youtubeURL: URL {
        var components = URLComponents(string: "https://www.youtube.com/playlist")!
        components.queryItems = [URLQueryItem(name: "list", value: id)]
        return components.url!
    }
}

actor YouTubeAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, accessToken: String) async throws -> [YouTubeVideo] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let payload: SearchResponse = try await request(
            path: "search",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(name: "videoEmbeddable", value: "true"),
                URLQueryItem(name: "maxResults", value: "25"),
                URLQueryItem(name: "q", value: query),
            ],
            accessToken: accessToken
        )
        return payload.items.compactMap(\.video)
    }

    func video(id: String, accessToken: String) async throws -> YouTubeVideo? {
        let payload: VideoResponse = try await request(
            path: "videos",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "id", value: id),
            ],
            accessToken: accessToken
        )
        return payload.items.first?.video
    }

    func subscriptions(accessToken: String) async throws -> [YouTubeSubscription] {
        let payload: SubscriptionResponse = try await request(
            path: "subscriptions",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "order", value: "relevance"),
                URLQueryItem(name: "maxResults", value: "50"),
            ],
            accessToken: accessToken,
            requiresAccountChannel: true
        )
        return payload.items.compactMap(\.subscription)
    }

    func likedVideos(accessToken: String) async throws -> [YouTubeVideo] {
        let payload: VideoResponse = try await request(
            path: "videos",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "myRating", value: "like"),
                URLQueryItem(name: "maxResults", value: "50"),
            ],
            accessToken: accessToken,
            requiresAccountChannel: true
        )
        return payload.items.map(\.video)
    }

    func playlists(accessToken: String) async throws -> [YouTubePlaylist] {
        let payload: PlaylistResponse = try await request(
            path: "playlists",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "mine", value: "true"),
                URLQueryItem(name: "maxResults", value: "50"),
            ],
            accessToken: accessToken,
            requiresAccountChannel: true
        )
        return payload.items.map(\.playlist)
    }

    func playlistVideos(playlistID: String, accessToken: String) async throws -> [YouTubeVideo] {
        let payload: PlaylistItemsResponse = try await request(
            path: "playlistItems",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "playlistId", value: playlistID),
                URLQueryItem(name: "maxResults", value: "50"),
            ],
            accessToken: accessToken
        )
        return payload.items.compactMap(\.video)
    }

    func recentVideos(channelID: String, accessToken: String) async throws -> [YouTubeVideo] {
        let payload: SearchResponse = try await request(
            path: "search",
            queryItems: [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "channelId", value: channelID),
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(name: "videoEmbeddable", value: "true"),
                URLQueryItem(name: "order", value: "date"),
                URLQueryItem(name: "maxResults", value: "25"),
            ],
            accessToken: accessToken
        )
        return payload.items.compactMap(\.video)
    }

    private func request<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem],
        accessToken: String,
        requiresAccountChannel: Bool = false
    ) async throws -> Response {
        guard !accessToken.isEmpty else { throw YouTubeAPIError.missingCredentials }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(path)")!
        components.queryItems = queryItems
        guard let url = components.url else { throw YouTubeAPIError.invalidRequest }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeAPIError.requestFailed("YouTube did not return an HTTP response.")
        }
        guard 200 ..< 300 ~= http.statusCode else {
            let errorResponse = try? JSONDecoder().decode(YouTubeErrorResponse.self, from: data)
            if http.statusCode == 401 { throw YouTubeAPIError.authorizationExpired }
            if requiresAccountChannel, errorResponse?.indicatesMissingAccountChannel == true {
                throw YouTubeAPIError.accountChannelRequired
            }
            throw YouTubeAPIError.requestFailed(
                errorResponse?.error.message ?? "YouTube request failed (HTTP \(http.statusCode))."
            )
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

enum YouTubeAPIError: LocalizedError {
    case missingCredentials
    case invalidRequest
    case authorizationExpired
    case accountChannelRequired
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Sign in with Google to use YouTube."
        case .invalidRequest:
            "The YouTube request could not be created."
        case .authorizationExpired:
            "Google authorization expired. Sign in again."
        case .accountChannelRequired:
            "This Google account has no available YouTube channel. Switch accounts or create a YouTube channel, then try again."
        case .requestFailed(let message):
            message
        }
    }
}

enum YouTubeVideoIDParser {
    static func parse(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
            return trimmed
        }
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased() else { return nil }
        if host == "youtu.be" {
            return components.path.split(separator: "/").first.map(String.init)
        }
        if host.hasSuffix("youtube.com") {
            if let videoID = components.queryItems?.first(where: { $0.name == "v" })?.value {
                return videoID
            }
            let parts = components.path.split(separator: "/")
            if let marker = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }),
               parts.indices.contains(marker + 1) {
                return String(parts[marker + 1])
            }
        }
        return nil
    }
}

private struct SearchResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: ID
        let snippet: YouTubeAPISnippet

        var video: YouTubeVideo? {
            guard let videoID = id.videoId else { return nil }
            return snippet.video(id: videoID)
        }
    }

    struct ID: Decodable {
        let videoId: String?
    }
}

private struct VideoResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: String
        let snippet: YouTubeAPISnippet

        var video: YouTubeVideo { snippet.video(id: id) }
    }
}

private struct SubscriptionResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: String
        let snippet: YouTubeAPISnippet

        var subscription: YouTubeSubscription? {
            guard let channelID = snippet.resourceId?.channelId else { return nil }
            return YouTubeSubscription(
                id: id,
                channelID: channelID,
                title: snippet.title.decodingHTMLEntities,
                thumbnailURL: snippet.thumbnailURL
            )
        }
    }
}

private struct PlaylistResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: String
        let snippet: YouTubeAPISnippet
        let contentDetails: ContentDetails

        var playlist: YouTubePlaylist {
            YouTubePlaylist(
                id: id,
                title: snippet.title.decodingHTMLEntities,
                itemCount: contentDetails.itemCount,
                thumbnailURL: snippet.thumbnailURL
            )
        }
    }

    struct ContentDetails: Decodable {
        let itemCount: Int
    }
}

private struct PlaylistItemsResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let snippet: YouTubeAPISnippet

        var video: YouTubeVideo? {
            guard let videoID = snippet.resourceId?.videoId else { return nil }
            return snippet.video(id: videoID)
        }
    }
}

private struct YouTubeAPISnippet: Decodable {
    let title: String
    let channelTitle: String?
    let thumbnails: Thumbnails?
    let resourceId: ResourceID?

    var thumbnailURL: URL? {
        thumbnails?.high?.url ?? thumbnails?.medium?.url ?? thumbnails?.default?.url
    }

    func video(id: String) -> YouTubeVideo {
        YouTubeVideo(
            id: id,
            title: title.decodingHTMLEntities,
            channelTitle: channelTitle ?? "YouTube",
            thumbnailURL: thumbnailURL
        )
    }

    struct Thumbnails: Decodable {
        let `default`: Thumbnail?
        let medium: Thumbnail?
        let high: Thumbnail?
    }

    struct Thumbnail: Decodable {
        let url: URL
    }

    struct ResourceID: Decodable {
        let videoId: String?
        let channelId: String?
    }
}

private struct YouTubeErrorResponse: Decodable {
    let error: Payload

    struct Payload: Decodable {
        let message: String
        let errors: [Detail]?
    }

    struct Detail: Decodable {
        let reason: String?
    }

    var indicatesMissingAccountChannel: Bool {
        let reasons = Set(error.errors?.compactMap(\.reason) ?? [])
        if !reasons.isDisjoint(with: ["youtubeSignupRequired", "subscriberNotFound", "channelNotFound"]) {
            return true
        }
        return error.message.localizedCaseInsensitiveContains("channel not found")
    }
}

private extension String {
    var decodingHTMLEntities: String {
        guard let data = data(using: .utf8) else { return self }
        return (try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        ).string) ?? self
    }
}
