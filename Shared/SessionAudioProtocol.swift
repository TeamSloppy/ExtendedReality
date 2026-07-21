import Foundation

struct SessionAudioConfiguration: Codable, Equatable, Sendable {
    static let sampleRate = 48_000
    static let playbackChannels = 2
    static let microphoneChannels = 1

    let version: Int
    let playbackURL: URL
    let microphoneURL: URL
    let sampleRate: Int
    let playbackChannels: Int
    let microphoneChannels: Int

    init(
        version: Int = 1,
        playbackURL: URL,
        microphoneURL: URL,
        sampleRate: Int = Self.sampleRate,
        playbackChannels: Int = Self.playbackChannels,
        microphoneChannels: Int = Self.microphoneChannels
    ) {
        self.version = version
        self.playbackURL = playbackURL
        self.microphoneURL = microphoneURL
        self.sampleRate = sampleRate
        self.playbackChannels = playbackChannels
        self.microphoneChannels = microphoneChannels
    }

    var isSupported: Bool {
        version == 1
            && sampleRate == Self.sampleRate
            && playbackChannels == Self.playbackChannels
            && microphoneChannels == Self.microphoneChannels
    }
}
