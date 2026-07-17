import Foundation

struct MacStreamEndpoint: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
}

struct MacStreamSession: Codable, Equatable, Sendable {
    let version: Int
    let layout: RemoteDisplayLayout
    let streams: [MacStreamEndpoint]
}

struct MacStreamAPIError: Codable, Equatable, Sendable {
    let error: String
}
