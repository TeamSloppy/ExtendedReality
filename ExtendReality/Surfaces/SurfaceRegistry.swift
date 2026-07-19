import Foundation
import WebKit

@MainActor
final class SurfaceRegistry {
    let inputRouter: InputRouter
    private unowned let workspace: WorkspaceStore
    private let keychain: KeychainStore
    private let pwaCapabilityProvider: (String, PWACapability) -> Bool
    private let pwaDataProvider: (PWACapability) throws -> [String: Any]
    private var browsers: [UUID: BrowserSession] = [:]
    private var pwaBrowsers: [UUID: BrowserSession] = [:]
    private var pwaPanelBrowsers: [SpatialPanelSurfaceID: BrowserSession] = [:]
    private var media: [UUID: MediaSession] = [:]
    private var youtube: [UUID: YouTubeSession] = [:]
    private var youtubePanelTargets: [SpatialPanelSurfaceID: YouTubePanelInputTarget] = [:]
    private var remoteDesktops: [UUID: RoyalVNCSession] = [:]
    private var macStreams: [UUID: BrowserSession] = [:]

    init(
        inputRouter: InputRouter,
        workspace: WorkspaceStore,
        keychain: KeychainStore,
        pwaCapabilityProvider: @escaping (String, PWACapability) -> Bool,
        pwaDataProvider: @escaping (PWACapability) throws -> [String: Any]
    ) {
        self.inputRouter = inputRouter
        self.workspace = workspace
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
        let allowedOrigins = try? Set(installation.manifest.allowedOrigins.map(PWAOrigin.init(rawValue:)))
        let windowClient = allowedOrigins.map { origins in
            SpatialWindowClient(
                windowID: id,
                workspace: workspace,
                allowedOrigins: origins,
                permissionProvider: { [pwaCapabilityProvider] in
                    pwaCapabilityProvider(appID, .spatialWindows)
                },
                layoutDidChange: { [weak self] layout in
                    self?.reconcilePwaPanels(windowID: id, layout: layout)
                }
            )
        }
        let session = BrowserSession(
            initialURL: launchURL.absoluteString,
            websiteDataStore: dataStore,
            navigationPolicy: policy,
            capabilityProvider: { [pwaCapabilityProvider] capability in
                pwaCapabilityProvider(appID, capability)
            },
            dataProvider: { [pwaDataProvider] capability in
                try pwaDataProvider(capability)
            },
            spatialWindowClient: windowClient
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
        for panelID: SpatialPanelID in ["video", "info", "search", "transport"] {
            let surfaceID = SpatialPanelSurfaceID(windowID: id, panelID: panelID)
            let target = YouTubePanelInputTarget(panelID: panelID, session: session)
            youtubePanelTargets[surfaceID] = target
            inputRouter.register(target, for: panelID, in: id)
        }
        return session
    }

    func pwaPanel(
        for windowID: UUID,
        panelID: SpatialPanelID,
        installation: PWAInstallation,
        initialURL: URL
    ) -> BrowserSession {
        let surfaceID = SpatialPanelSurfaceID(windowID: windowID, panelID: panelID)
        if let session = pwaPanelBrowsers[surfaceID] {
            if session.address != initialURL.absoluteString { session.load(initialURL.absoluteString) }
            return session
        }
        let policy = try? PWAOriginPolicy(manifest: installation.manifest)
        let dataStore = WKWebsiteDataStore(forIdentifier: installation.dataStoreIdentifier)
        let appID = installation.id
        let session = BrowserSession(
            initialURL: initialURL.absoluteString,
            websiteDataStore: dataStore,
            navigationPolicy: policy,
            capabilityProvider: { [pwaCapabilityProvider] capability in
                pwaCapabilityProvider(appID, capability)
            },
            dataProvider: { [pwaDataProvider] capability in
                try pwaDataProvider(capability)
            }
        )
        pwaPanelBrowsers[surfaceID] = session
        inputRouter.register(session, for: panelID, in: windowID)
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
        pwaPanelBrowsers = pwaPanelBrowsers.filter { $0.key.windowID != windowID }
        media.removeValue(forKey: windowID)
        youtube.removeValue(forKey: windowID)
        youtubePanelTargets = youtubePanelTargets.filter { $0.key.windowID != windowID }
        macStreams.removeValue(forKey: windowID)
        remoteDesktops.removeValue(forKey: windowID)?.disconnect()
    }

    func removePanels(windowID: UUID) {
        pwaPanelBrowsers = pwaPanelBrowsers.filter { $0.key.windowID != windowID }
        inputRouter.removePanelLayouts(for: windowID)
    }

    private func reconcilePwaPanels(windowID: UUID, layout: SpatialAppLayout?) {
        let retainedIDs = Set(layout?.panels.compactMap { panel -> SpatialPanelID? in
            if case .web = panel.content { return panel.id }
            return nil
        } ?? [])
        pwaPanelBrowsers = pwaPanelBrowsers.filter { surfaceID, _ in
            surfaceID.windowID != windowID || retainedIDs.contains(surfaceID.panelID)
        }
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
