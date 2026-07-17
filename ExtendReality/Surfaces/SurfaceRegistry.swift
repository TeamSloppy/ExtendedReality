import Foundation

@MainActor
final class SurfaceRegistry {
    private let inputRouter: InputRouter
    private let keychain: KeychainStore
    private var browsers: [UUID: BrowserSession] = [:]
    private var media: [UUID: MediaSession] = [:]
    private var youtube: [UUID: YouTubeSession] = [:]
    private var remoteDesktops: [UUID: RoyalVNCSession] = [:]

    init(inputRouter: InputRouter, keychain: KeychainStore) {
        self.inputRouter = inputRouter
        self.keychain = keychain
    }

    func prepare(for windows: [WorkspaceWindow]) {
        for window in windows {
            switch window.source {
            case .browser(let url): _ = browser(for: window.id, initialURL: url)
            case .gallery: _ = mediaSession(for: window.id)
            case .youtube(let videoID): _ = youtubeSession(for: window.id, initialVideoID: videoID)
            case .remoteDesktop(let host): _ = remoteDesktop(for: window.id, initialHost: host)
            }
        }
    }

    func browser(for id: UUID, initialURL: String = "https://www.apple.com") -> BrowserSession {
        if let session = browsers[id] { return session }
        let session = BrowserSession(initialURL: initialURL)
        browsers[id] = session
        inputRouter.register(session, for: id)
        return session
    }

    func mediaSession(for id: UUID) -> MediaSession {
        if let session = media[id] { return session }
        let session = MediaSession()
        media[id] = session
        inputRouter.register(session, for: id)
        return session
    }

    func youtubeSession(for id: UUID, initialVideoID: String? = nil) -> YouTubeSession {
        if let session = youtube[id] { return session }
        let session = YouTubeSession(initialVideoID: initialVideoID)
        youtube[id] = session
        inputRouter.register(session, for: id)
        return session
    }

    func remoteDesktop(for id: UUID, initialHost: String? = nil) -> RoyalVNCSession {
        if let session = remoteDesktops[id] { return session }
        let session = RoyalVNCSession(windowID: id, keychain: keychain, initialHost: initialHost)
        remoteDesktops[id] = session
        inputRouter.register(session, for: id)
        return session
    }

    func remove(windowID: UUID) {
        browsers.removeValue(forKey: windowID)
        media.removeValue(forKey: windowID)
        youtube.removeValue(forKey: windowID)
        remoteDesktops.removeValue(forKey: windowID)?.disconnect()
    }
}

