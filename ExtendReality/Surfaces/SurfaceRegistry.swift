import Foundation
import WebKit

@MainActor
final class SurfaceRegistry {
    private let inputRouter: InputRouter
    private let keychain: KeychainStore
    private let pwaCapabilityProvider: (String, PWACapability) -> Bool
    private let pwaDataProvider: (PWACapability) throws -> [String: Any]
    private var browsers: [UUID: BrowserSession] = [:]
    private var pwaBrowsers: [UUID: BrowserSession] = [:]
    private var media: [UUID: MediaSession] = [:]
    private var youtube: [UUID: YouTubeSession] = [:]
    private var remoteDesktops: [UUID: RoyalVNCSession] = [:]
    private var macStreams: [UUID: BrowserSession] = [:]

    init(
        inputRouter: InputRouter,
        keychain: KeychainStore,
        pwaCapabilityProvider: @escaping (String, PWACapability) -> Bool,
        pwaDataProvider: @escaping (PWACapability) throws -> [String: Any]
    ) {
        self.inputRouter = inputRouter
        self.keychain = keychain
        self.pwaCapabilityProvider = pwaCapabilityProvider
        self.pwaDataProvider = pwaDataProvider
    }

    func prepare(for windows: [WorkspaceWindow]) {
        for window in windows {
            switch window.source {
            case .browser(let url): _ = browser(for: window.id, initialURL: url)
            case .pwa(let installation, let displayMode):
                _ = pwa(for: window.id, installation: installation, displayMode: displayMode)
            case .gallery: _ = mediaSession(for: window.id)
            case .youtube(let videoID): _ = youtubeSession(for: window.id, initialVideoID: videoID)
            case .remoteDesktop(let host):
                if let host, Self.isWebStreamAddress(host) {
                    _ = macStream(for: window.id, initialURL: host)
                } else {
                    _ = remoteDesktop(for: window.id, initialHost: host)
                }
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

    func pwa(
        for id: UUID,
        installation: PWAInstallation,
        displayMode: PWADisplayMode
    ) -> BrowserSession {
        if let session = pwaBrowsers[id] { return session }
        let launchURL = Self.launchURL(for: installation.manifest.launchURL, displayMode: displayMode)
        let policy = try? PWAOriginPolicy(manifest: installation.manifest)
        let dataStore = WKWebsiteDataStore(forIdentifier: installation.dataStoreIdentifier)
        let appID = installation.id
        let session = BrowserSession(
            initialURL: launchURL.absoluteString,
            websiteDataStore: dataStore,
            navigationPolicy: policy,
            capabilityProvider: { [pwaCapabilityProvider] capability in
                pwaCapabilityProvider(appID, capability)
            },
            dataProvider: { [pwaDataProvider] capability in
                try pwaDataProvider(capability)
            }
        )
        pwaBrowsers[id] = session
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

    func macStream(for id: UUID, initialURL: String) -> BrowserSession {
        if let session = macStreams[id] { return session }
        let session = BrowserSession(initialURL: initialURL)
        macStreams[id] = session
        inputRouter.register(session, for: id)
        return session
    }

    nonisolated static func isWebStreamAddress(_ address: String?) -> Bool {
        guard let address,
              let scheme = URL(string: address)?.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme)
    }

    func remove(windowID: UUID) {
        browsers.removeValue(forKey: windowID)
        pwaBrowsers.removeValue(forKey: windowID)
        media.removeValue(forKey: windowID)
        youtube.removeValue(forKey: windowID)
        macStreams.removeValue(forKey: windowID)
        remoteDesktops.removeValue(forKey: windowID)?.disconnect()
    }

    func removeWebsiteData(for identifier: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func launchURL(for baseURL: URL, displayMode: PWADisplayMode) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        var items = components.queryItems ?? []
        items.removeAll(where: { $0.name == "extendDisplayMode" })
        items.append(URLQueryItem(name: "extendDisplayMode", value: displayMode.rawValue))
        components.queryItems = items
        return components.url ?? baseURL
    }
}
