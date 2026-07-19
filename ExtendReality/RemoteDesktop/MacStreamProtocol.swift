import Foundation

struct MacStreamEndpoint: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
    let width: Int
    let height: Int

    var aspectRatio: Double? {
        guard width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }
}

struct MacStreamSession: Codable, Equatable, Sendable {
    let version: Int
    let layout: RemoteDisplayLayout
    let streams: [MacStreamEndpoint]
    let cursorURL: URL?

    init(
        version: Int,
        layout: RemoteDisplayLayout,
        streams: [MacStreamEndpoint],
        cursorURL: URL? = nil
    ) {
        self.version = version
        self.layout = layout
        self.streams = streams
        self.cursorURL = cursorURL
    }
}

struct MacCursorPosition: Codable, Equatable, Sendable {
    let version: Int
    let streamID: String?
    let x: Double?
    let y: Double?
    let visible: Bool
}

struct MacStreamAPIError: Codable, Equatable, Sendable {
    let error: String
}
