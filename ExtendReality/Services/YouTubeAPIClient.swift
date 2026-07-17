import Foundation

struct YouTubeVideo: Identifiable, Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let channelTitle: String
    let thumbnailURL: URL?
}

actor YouTubeAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, apiKey: String, accessToken: String? = nil) async throws -> [YouTubeVideo] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard !apiKey.isEmpty || accessToken != nil else { throw YouTubeAPIError.missingCredentials }

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        var queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoEmbeddable", value: "true"),
            URLQueryItem(name: "maxResults", value: "20"),
            URLQueryItem(name: "q", value: query),
        ]
        if !apiKey.isEmpty {
            queryItems.append(URLQueryItem(name: "key", value: apiKey))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw YouTubeAPIError.requestFailed
        }
        let payload = try JSONDecoder().decode(SearchResponse.self, from: data)
        return payload.items.compactMap { item in
            guard let videoID = item.id.videoId else { return nil }
            return YouTubeVideo(
                id: videoID,
                title: item.snippet.title.decodingHTMLEntities,
                channelTitle: item.snippet.channelTitle,
                thumbnailURL: item.snippet.thumbnails.medium?.url ?? item.snippet.thumbnails.default?.url
            )
        }
    }
}

enum YouTubeAPIError: LocalizedError {
    case missingCredentials
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Add a YouTube Data API key in Settings."
        case .requestFailed: "YouTube request failed."
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
        let snippet: Snippet
    }

    struct ID: Decodable {
        let videoId: String?
    }

    struct Snippet: Decodable {
        let title: String
        let channelTitle: String
        let thumbnails: Thumbnails
    }

    struct Thumbnails: Decodable {
        let `default`: Thumbnail?
        let medium: Thumbnail?
    }

    struct Thumbnail: Decodable {
        let url: URL
    }
}

private extension String {
    var decodingHTMLEntities: String {
        guard let data = data(using: .utf8) else { return self }
        return (try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ).string) ?? self
    }
}

