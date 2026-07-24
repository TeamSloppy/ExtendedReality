import AVKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum YouTubeBrowseSection: String, CaseIterable, Identifiable, Sendable {
    case subscriptions
    case liked
    case library
    case downloads

    var id: Self { self }

    var title: String {
        switch self {
        case .subscriptions: "Subscriptions"
        case .liked: "Liked"
        case .library: "Library"
        case .downloads: "Downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .subscriptions: "rectangle.stack.badge.play"
        case .liked: "hand.thumbsup.fill"
        case .library: "books.vertical.fill"
        case .downloads: "arrow.down.circle.fill"
        }
    }

    static let remoteCases: [Self] = [.subscriptions, .liked, .library]
}

private enum YouTubeLibraryLoadResult: Sendable {
    case subscriptions([YouTubeSubscription])
    case likedVideos([YouTubeVideo])
    case playlists([YouTubePlaylist])
    case failure(YouTubeBrowseSection, String)
    case cancelled(YouTubeBrowseSection)
}

@MainActor
private final class YouTubePlayerMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: YouTubeSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "extendRealityPlayer",
              let payload = message.body as? [String: Any] else { return }
        session?.receivePlayerState(payload)
    }
}

@MainActor
@Observable
final class YouTubeSession: NSObject, InputTarget, WKNavigationDelegate {
    var videoID: String?
    var query = ""
    var selectedSection = YouTubeBrowseSection.subscriptions
    private(set) var currentVideo: YouTubeVideo?
    private(set) var currentDownload: YouTubeDownload?
    private(set) var localPlayer: AVPlayer?
    private(set) var results: [YouTubeVideo] = []
    private(set) var subscriptions: [YouTubeSubscription] = []
    private(set) var likedVideos: [YouTubeVideo] = []
    private(set) var playlists: [YouTubePlaylist] = []
    private(set) var collectionTitle: String?
    private(set) var collectionVideos: [YouTubeVideo] = []
    private(set) var isShowingHome: Bool
    private(set) var loadingLibrarySections: Set<YouTubeBrowseSection> = []
    private(set) var loadedLibrarySections: Set<YouTubeBrowseSection> = []
    private(set) var libraryErrorMessages: [YouTubeBrowseSection: String] = [:]
    private(set) var isLoadingCollection = false
    private(set) var collectionErrorMessage: String?
    private(set) var isSearching = false
    private(set) var searchErrorMessage: String?
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var currentTime = 0.0
    private(set) var duration = 0.0
    private(set) var playerErrorMessage: String?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let playerMessageHandler: YouTubePlayerMessageHandler
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var libraryTask: Task<Void, Never>?
    @ObservationIgnored private var collectionTask: Task<Void, Never>?
    @ObservationIgnored private var localPlaybackTask: Task<Void, Never>?
    @ObservationIgnored private let apiClient: YouTubeAPIClient
    @ObservationIgnored let authSession: YouTubeAuthSession
    @ObservationIgnored let downloadStore: YouTubeDownloadStore
    @ObservationIgnored private let playerOrigin: URL
    @ObservationIgnored private let textInputFocusHandler: (String) -> Void
    @ObservationIgnored private let playbackStateDidChange: () -> Void
    @ObservationIgnored private let spatialPresentationDidChange: (Bool) -> Void

    init(
        initialVideoID: String?,
        loadsContent: Bool = true,
        appIdentifier: String? = Bundle.main.bundleIdentifier,
        apiClient: YouTubeAPIClient = YouTubeAPIClient(),
        authSession: YouTubeAuthSession? = nil,
        downloadStore: YouTubeDownloadStore? = nil,
        textInputFocusHandler: @escaping (String) -> Void = { _ in },
        playbackStateDidChange: @escaping () -> Void = {},
        spatialPresentationDidChange: @escaping (Bool) -> Void = { _ in }
    ) {
        videoID = initialVideoID
        isShowingHome = initialVideoID == nil
        self.apiClient = apiClient
        self.authSession = authSession ?? YouTubeAuthSession(restoresPreviousSignIn: loadsContent)
        self.downloadStore = downloadStore ?? YouTubeDownloadStore()
        self.textInputFocusHandler = textInputFocusHandler
        self.playbackStateDidChange = playbackStateDidChange
        self.spatialPresentationDidChange = spatialPresentationDidChange
        playerOrigin = YouTubePlayerClientIdentity.origin(appIdentifier: appIdentifier)
        let handler = YouTubePlayerMessageHandler()
        playerMessageHandler = handler
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(handler, name: "extendRealityPlayer")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        handler.session = self
        webView.navigationDelegate = self
        if loadsContent { loadPlayer(videoID: initialVideoID) }
    }

    func load(_ value: String) {
        guard let parsed = YouTubeVideoIDParser.parse(value) else { return }
        clearLocalPlayback()
        videoID = parsed
        currentVideo = nil
        results = []
        isShowingHome = false
        loadPlayer(videoID: parsed)
        loadMetadata(for: parsed)
        notifySpatialPresentationChanged()
    }

    func load(video: YouTubeVideo) {
        clearLocalPlayback()
        videoID = video.id
        currentVideo = video
        isShowingHome = false
        loadPlayer(videoID: video.id)
        notifySpatialPresentationChanged()
    }

    func load(download: YouTubeDownload) {
        guard let url = downloadStore.fileURL(for: download) else {
            downloadStore.report(YouTubeDownloadError.missingFile)
            return
        }
        webView.evaluateJavaScript("player && player.pauseVideo();")
        localPlaybackTask?.cancel()
        let player = AVPlayer(url: url)
        localPlayer = player
        currentDownload = download
        currentVideo = nil
        videoID = download.youtubeVideoID
        isShowingHome = false
        isReady = true
        isPlaying = true
        currentTime = 0
        duration = 0
        playerErrorMessage = nil
        player.play()
        observeLocalPlayback(player)
        notifySpatialPresentationChanged()
    }

    func download(_ video: YouTubeVideo) {
        downloadStore.download(video)
    }

    func importVideo(from url: URL) {
        do {
            try downloadStore.importVideo(from: url)
            selectedSection = .downloads
        } catch {
            downloadStore.report(error)
        }
    }

    func delete(_ download: YouTubeDownload) {
        if currentDownload?.id == download.id {
            showHome()
            clearLocalPlayback()
        }
        downloadStore.delete(download)
    }

    func showHome() {
        pause()
        isShowingHome = true
        ensureLibraryLoaded()
        notifySpatialPresentationChanged()
    }

    func signIn() {
        Task { [weak self] in
            guard let self else { return }
            await authSession.signIn()
            authorizationDidChange()
        }
    }

    func switchAccount() {
        Task { [weak self] in
            guard let self, await authSession.switchAccount() else { return }
            resetLibrary()
            authorizationDidChange()
        }
    }

    var isLoadingLibrary: Bool {
        !loadingLibrarySections.isEmpty || isLoadingCollection
    }

    var isLoadingDisplayedLibraryContent: Bool {
        if collectionTitle != nil { return isLoadingCollection }
        if selectedSection == .downloads { return !downloadStore.activityByVideoID.isEmpty }
        return isLoading(selectedSection)
    }

    var displayedLibraryErrorMessage: String? {
        if collectionTitle != nil { return collectionErrorMessage }
        if selectedSection == .downloads { return downloadStore.errorMessage }
        return libraryErrorMessage(for: selectedSection)
    }

    func isLoading(_ section: YouTubeBrowseSection) -> Bool {
        loadingLibrarySections.contains(section)
    }

    func libraryErrorMessage(for section: YouTubeBrowseSection) -> String? {
        libraryErrorMessages[section]
    }

    func ensureLibraryLoaded(force: Bool = false) {
        guard authSession.isSignedIn else { return }
        if !force,
           !loadingLibrarySections.isEmpty
            || !loadedLibrarySections.isEmpty
            || !libraryErrorMessages.isEmpty
            || !subscriptions.isEmpty
            || !likedVideos.isEmpty
            || !playlists.isEmpty {
            return
        }
        loadLibrary()
    }

    func loadLibrary() {
        guard authSession.isSignedIn else {
            let message = YouTubeAuthError.authorizationRequired.localizedDescription
            libraryErrorMessages = Dictionary(
                uniqueKeysWithValues: YouTubeBrowseSection.remoteCases.map { ($0, message) }
            )
            return
        }
        libraryTask?.cancel()
        loadingLibrarySections = Set(YouTubeBrowseSection.remoteCases)
        loadedLibrarySections = []
        libraryErrorMessages = [:]
        libraryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authSession.accessToken()
                await withTaskGroup(of: YouTubeLibraryLoadResult.self) { group in
                    group.addTask { [apiClient] in
                        do {
                            return .subscriptions(try await apiClient.subscriptions(accessToken: token))
                        } catch is CancellationError {
                            return .cancelled(.subscriptions)
                        } catch {
                            return .failure(.subscriptions, error.localizedDescription)
                        }
                    }
                    group.addTask { [apiClient] in
                        do {
                            return .likedVideos(try await apiClient.likedVideos(accessToken: token))
                        } catch is CancellationError {
                            return .cancelled(.liked)
                        } catch {
                            return .failure(.liked, error.localizedDescription)
                        }
                    }
                    group.addTask { [apiClient] in
                        do {
                            return .playlists(try await apiClient.playlists(accessToken: token))
                        } catch is CancellationError {
                            return .cancelled(.library)
                        } catch {
                            return .failure(.library, error.localizedDescription)
                        }
                    }

                    for await result in group {
                        guard !Task.isCancelled else {
                            group.cancelAll()
                            return
                        }
                        applyLibraryLoadResult(result)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                libraryErrorMessages = Dictionary(
                    uniqueKeysWithValues: YouTubeBrowseSection.remoteCases.map { ($0, message) }
                )
                loadingLibrarySections = []
            }
        }
    }

    func open(subscription: YouTubeSubscription) {
        loadCollection(title: subscription.title) { [apiClient] token in
            try await apiClient.recentVideos(channelID: subscription.channelID, accessToken: token)
        }
    }

    func open(playlist: YouTubePlaylist) {
        loadCollection(title: playlist.title) { [apiClient] token in
            try await apiClient.playlistVideos(playlistID: playlist.id, accessToken: token)
        }
    }

    func closeCollection() {
        collectionTask?.cancel()
        collectionTitle = nil
        collectionVideos = []
        collectionErrorMessage = nil
        isLoadingCollection = false
    }

    func authorizationDidChange() {
        if authSession.isSignedIn {
            ensureLibraryLoaded()
            if let videoID, currentVideo == nil { loadMetadata(for: videoID) }
        } else {
            libraryTask?.cancel()
            collectionTask?.cancel()
            resetLibrary()
            isShowingHome = true
        }
        notifySpatialPresentationChanged()
    }

    func submitSearch() {
        searchErrorMessage = nil
        if YouTubeVideoIDParser.parse(query) != nil {
            load(query)
            return
        }
        guard authSession.isSignedIn else {
            searchErrorMessage = YouTubeAuthError.authorizationRequired.localizedDescription
            return
        }
        let submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submittedQuery.isEmpty else {
            results = []
            return
        }
        searchTask?.cancel()
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authSession.accessToken()
                let found = try await apiClient.search(query: submittedQuery, accessToken: token)
                guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == submittedQuery else { return }
                results = found
                isSearching = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                isSearching = false
                searchErrorMessage = error.localizedDescription
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        query = ""
        results = []
        searchErrorMessage = nil
        isSearching = false
    }

    func play() {
        if let localPlayer {
            localPlayer.play()
            isPlaying = true
            playbackStateDidChange()
        } else {
            webView.evaluateJavaScript("player && player.playVideo();")
        }
    }

    func pause() {
        if let localPlayer {
            localPlayer.pause()
            isPlaying = false
            playbackStateDidChange()
        } else {
            webView.evaluateJavaScript("player && player.pauseVideo();")
        }
    }

    func seek(seconds: Double) {
        if let localPlayer {
            let target = max(0, localPlayer.currentTime().seconds + seconds)
            localPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        } else {
            webView.evaluateJavaScript("player && player.seekTo(Math.max(0, player.getCurrentTime() + \(seconds)), true);")
        }
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        if let localPlayer {
            localPlayer.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600))
        } else {
            webView.evaluateJavaScript("player && player.seekTo(\(max(0, time)), true);")
        }
    }

    func handle(_ command: InputCommand) {
        handle(command, in: "video")
    }

    func handle(_ command: InputCommand, in panelID: SpatialPanelID) {
        switch command {
        case .media(let media):
            handle(media)
        case .back:
            pause()
        case .insertText(let text) where panelID == "search":
            query = text
        case .replaceText(let text) where panelID == "search":
            query = text
        case .submitText(let text) where panelID == "search":
            query = text
            submitSearch()
        case .pointerUp(let position) where panelID == "search":
            handleSearchClick(at: position)
        case .pointerUp(let position) where panelID == "transport":
            handleTransportClick(at: position)
        case .pointerUp(let position) where !authSession.isSignedIn
            && position.x >= 0.25
            && position.x <= 0.75
            && position.y >= 0.44
            && position.y <= 0.82:
            signIn()
        case .pointerUp(let position) where panelID == "video"
            && position.x < 0.24
            && position.y < 0.18:
            showHome()
        default:
            break
        }
    }

    func receivePlayerState(_ payload: [String: Any]) {
        let wasPlaying = isPlaying
        if let errorCode = payload["error"] as? Int {
            playerErrorMessage = Self.errorMessage(for: errorCode)
            isReady = false
            isPlaying = false
        }
        if let state = payload["state"] as? Int { isPlaying = state == 1 }
        if let time = payload["time"] as? Double, time.isFinite { currentTime = time }
        if let duration = payload["duration"] as? Double, duration.isFinite { self.duration = duration }
        if payload["ready"] as? Bool == true {
            playerErrorMessage = nil
            isReady = true
        }
        if isPlaying != wasPlaying {
            playbackStateDidChange()
        }
    }

    private func handle(_ media: MediaCommand) {
        switch media {
        case .play: play()
        case .pause: pause()
        case .togglePlayback: isPlaying ? pause() : play()
        case .seek(let seconds): seek(seconds: seconds)
        }
    }

    private func handleSearchClick(at position: CGPoint) {
        if position.y < 0.18 {
            if position.x > 0.78, !query.isEmpty {
                clearSearch()
            } else {
                textInputFocusHandler(query)
            }
            return
        }
        let resultHeight = 0.16
        let index = Int((position.y - 0.20) / resultHeight)
        if results.indices.contains(index) { load(video: results[index]) }
    }

    private func handleTransportClick(at position: CGPoint) {
        if position.y > 0.62, duration > 0 {
            seek(to: duration * position.x.clamped(to: 0 ... 1))
        } else if position.x < 0.25 {
            seek(seconds: -10)
        } else if position.x > 0.75 {
            seek(seconds: 10)
        } else {
            isPlaying ? pause() : play()
        }
    }

    private func loadMetadata(for videoID: String) {
        guard authSession.isSignedIn else { return }
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authSession.accessToken()
                let video = try await apiClient.video(id: videoID, accessToken: token)
                guard !Task.isCancelled, self.videoID == videoID else { return }
                currentVideo = video
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func loadCollection(
        title: String,
        loader: @escaping @Sendable (String) async throws -> [YouTubeVideo]
    ) {
        collectionTask?.cancel()
        collectionTitle = title
        collectionVideos = []
        isLoadingCollection = true
        collectionErrorMessage = nil
        collectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authSession.accessToken()
                let videos = try await loader(token)
                guard !Task.isCancelled, collectionTitle == title else { return }
                collectionVideos = videos
                isLoadingCollection = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingCollection = false
                collectionErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyLibraryLoadResult(_ result: YouTubeLibraryLoadResult) {
        switch result {
        case .subscriptions(let values):
            subscriptions = values
            loadedLibrarySections.insert(.subscriptions)
            libraryErrorMessages[.subscriptions] = nil
            loadingLibrarySections.remove(.subscriptions)
        case .likedVideos(let values):
            likedVideos = values
            loadedLibrarySections.insert(.liked)
            libraryErrorMessages[.liked] = nil
            loadingLibrarySections.remove(.liked)
        case .playlists(let values):
            playlists = values
            loadedLibrarySections.insert(.library)
            libraryErrorMessages[.library] = nil
            loadingLibrarySections.remove(.library)
        case .failure(let section, let message):
            libraryErrorMessages[section] = message
            loadingLibrarySections.remove(section)
        case .cancelled(let section):
            loadingLibrarySections.remove(section)
        }
    }

    private func resetLibrary() {
        libraryTask?.cancel()
        collectionTask?.cancel()
        subscriptions = []
        likedVideos = []
        playlists = []
        loadingLibrarySections = []
        loadedLibrarySections = []
        libraryErrorMessages = [:]
        closeCollection()
    }

    private func observeLocalPlayback(_ player: AVPlayer) {
        localPlaybackTask = Task { [weak self, weak player] in
            guard let self, let player else { return }
            if let asset = player.currentItem?.asset,
               let loadedDuration = try? await asset.load(.duration),
               loadedDuration.seconds.isFinite {
                duration = loadedDuration.seconds
            }
            while !Task.isCancelled, localPlayer === player {
                let wasPlaying = isPlaying
                let time = player.currentTime().seconds
                if time.isFinite { currentTime = time }
                isPlaying = player.rate > 0
                if isPlaying != wasPlaying { playbackStateDidChange() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func clearLocalPlayback() {
        localPlaybackTask?.cancel()
        localPlaybackTask = nil
        localPlayer?.pause()
        localPlayer = nil
        currentDownload = nil
    }

    var showsSpatialComposition: Bool {
        authSession.isSignedIn || currentDownload != nil
    }

    private func notifySpatialPresentationChanged() {
        spatialPresentationDidChange(showsSpatialComposition)
    }

    private func loadPlayer(videoID: String?) {
        clearLocalPlayback()
        isReady = false
        isPlaying = false
        currentTime = 0
        duration = 0
        playerErrorMessage = nil
        playbackStateDidChange()
        let id = videoID ?? ""
        let origin = "\(playerOrigin.scheme ?? "https")://\(playerOrigin.host ?? "com.vladprusakov.extendreality")"
        let html = """
            <!doctype html>
            <html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
            <meta name="referrer" content="strict-origin-when-cross-origin">
            <style>html,body,#player{width:100%;height:100%;margin:0;background:#000;overflow:hidden}</style>
            </head><body><div id="player"></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
              var player;
              const send = extra => window.webkit.messageHandlers.extendRealityPlayer.postMessage(Object.assign({
                state: player && player.getPlayerState ? player.getPlayerState() : -1,
                time: player && player.getCurrentTime ? player.getCurrentTime() : 0,
                duration: player && player.getDuration ? player.getDuration() : 0
              }, extra || {}));
              function onYouTubeIframeAPIReady(){
                player = new YT.Player('player', {
                  videoId: '\(id)',
                  playerVars: { playsinline: 1, controls: 0, rel: 0, origin: '\(origin)' },
                  events: {
                    onReady: function(){ send({ready:true}); setInterval(() => send(), 500); },
                    onStateChange: function(){ send(); },
                    onError: function(event){ send({error:event.data}); }
                  }
                });
              }
            </script></body></html>
            """
        webView.loadHTMLString(html, baseURL: playerOrigin)
    }

    private static func errorMessage(for code: Int) -> String {
        switch code {
        case 2: "The YouTube video ID is invalid."
        case 5: "YouTube could not play this video in HTML5."
        case 100: "This YouTube video is unavailable or private."
        case 101, 150: "The creator disabled embedded playback for this video."
        case 153: "YouTube rejected the app identity. Update ExtendReality and try again."
        default: "YouTube player error \(code)."
        }
    }
}

enum YouTubePlayerClientIdentity {
    private static let fallbackAppIdentifier = "com.vladprusakov.ExtendReality"

    static func origin(appIdentifier: String?) -> URL {
        let trimmed = appIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isValid = !trimmed.isEmpty
            && trimmed.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil
        let identifier = isValid ? trimmed : fallbackAppIdentifier
        return URL(string: "https://\(identifier.lowercased())/")!
    }
}

@MainActor
final class YouTubePanelInputTarget: InputTarget {
    let panelID: SpatialPanelID
    unowned let session: YouTubeSession

    init(panelID: SpatialPanelID, session: YouTubeSession) {
        self.panelID = panelID
        self.session = session
    }

    func handle(_ command: InputCommand) {
        session.handle(command, in: panelID)
    }
}

private struct YouTubePlayerWebView: UIViewRepresentable {
    let session: YouTubeSession

    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

private enum SpatialVideoTheme {
    static let background = Color(red: 0.015, green: 0.015, blue: 0.03)
    static let panel = Color(red: 0.059, green: 0.059, blue: 0.137)
    static let panelStrong = Color(red: 0.078, green: 0.078, blue: 0.165)
    static let accent = Color(red: 0.882, green: 0.114, blue: 0.282)
    static let accentSoft = Color(red: 0.984, green: 0.443, blue: 0.522)
    static let muted = Color(red: 0.655, green: 0.678, blue: 0.741)
    static let line = Color.white.opacity(0.11)
}

private struct SpatialVideoBackdrop: View {
    var body: some View {
        ZStack {
            SpatialVideoTheme.background
            RadialGradient(
                colors: [SpatialVideoTheme.accent.opacity(0.2), .clear],
                center: UnitPoint(x: 0.5, y: 0.12),
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [Color.indigo.opacity(0.28), .clear],
                center: UnitPoint(x: 0.08, y: 0.92),
                startRadius: 0,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}

struct YouTubeSurfaceView: View {
    @Bindable var session: YouTubeSession

    var body: some View {
        Group {
            if session.isShowingHome || (!session.authSession.isSignedIn && session.localPlayer == nil) {
                YouTubeNativeHomeView(session: session)
            } else {
                YouTubePlayerSurfaceView(session: session)
            }
        }
        .task(id: session.authSession.isSignedIn) {
            session.authorizationDidChange()
        }
    }
}

private struct YouTubePlayerSurfaceView: View {
    @Bindable var session: YouTubeSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    session.showHome()
                    ControllerHaptics.selection()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to YouTube library")
                .accessibilityIdentifier("youtube.player.back")

                SpatialVideoAppMark(size: 32)
                Text("Spatial Video")
                    .font(.system(size: 14, weight: .bold, design: .rounded))

                Spacer()

                Label(
                    session.localPlayer == nil ? "Online" : "On Device",
                    systemImage: session.localPlayer == nil ? "wifi" : "internaldrive.fill"
                )
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.54), in: Capsule())
                    .overlay { Capsule().strokeBorder(SpatialVideoTheme.line) }
            }
            .padding(12)
            .foregroundStyle(.white)
            .background(.black.opacity(0.86))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(SpatialVideoTheme.line)
                    .frame(height: 1)
            }

            ZStack {
                SpatialVideoTheme.background
                if let player = session.localPlayer {
                    VideoPlayer(player: player)
                } else {
                    YouTubePlayerWebView(session: session)
                }

                if let error = session.playerErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(SpatialVideoTheme.accent.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SpatialVideoTheme.background)
    }
}

private struct SpatialVideoAppMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(SpatialVideoTheme.accent, in: RoundedRectangle(cornerRadius: size * 0.28))
            .shadow(color: SpatialVideoTheme.accent.opacity(0.34), radius: size * 0.3)
    }
}

struct YouTubeNativeHomeView: View {
    @Bindable var session: YouTubeSession
    @State private var isImportingVideo = false

    var body: some View {
        ZStack {
            SpatialVideoBackdrop()

            VStack(spacing: 16) {
                if session.authSession.isRestoring {
                    SpatialVideoAppMark(size: 48)
                    ProgressView("Restoring Google account…")
                        .tint(SpatialVideoTheme.accentSoft)
                } else if !session.authSession.isSignedIn, session.selectedSection != .downloads {
                    authorizationView
                } else if !session.authSession.isSignedIn {
                    offlineDownloadsView
                } else {
                    signedInHeader
                    libraryContent
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .task(id: session.authSession.isSignedIn) {
            session.authorizationDidChange()
        }
        .fileImporter(
            isPresented: $isImportingVideo,
            allowedContentTypes: [.movie, .video, .mpeg4Movie]
        ) { result in
            switch result {
            case .success(let url):
                session.importVideo(from: url)
            case .failure(let error):
                session.downloadStore.report(error)
            }
        }
    }

    private var authorizationView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SpatialVideoAppMark(size: 34)
                Text("Spatial Video")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Label("Private library", systemImage: "lock.fill")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(SpatialVideoTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.05), in: Capsule())
                    .overlay { Capsule().strokeBorder(SpatialVideoTheme.line) }
            }
            .padding(.bottom, 18)

            VStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(SpatialVideoTheme.accent.opacity(0.16))
                        .overlay { Circle().strokeBorder(SpatialVideoTheme.accentSoft.opacity(0.34)) }
                        .frame(width: 92, height: 92)
                        .shadow(color: SpatialVideoTheme.accent.opacity(0.28), radius: 28)
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 37, weight: .medium))
                        .foregroundStyle(.white)
                }

                Text("Your videos, in space")
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .tracking(-1.2)

                Text("Connect Google to open your subscriptions, liked videos, and private YouTube library.")
                    .font(.system(size: 13, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(SpatialVideoTheme.muted)
                    .frame(maxWidth: 470)

                if session.authSession.isAuthorizing {
                    ProgressView("Opening Google…")
                        .tint(SpatialVideoTheme.accentSoft)
                        .frame(height: 48)
                } else {
                    Button {
                        session.signIn()
                    } label: {
                        Label("Continue with Google", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(width: 240, height: 46)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(SpatialVideoTheme.accent, in: RoundedRectangle(cornerRadius: 13))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(SpatialVideoTheme.accentSoft.opacity(0.42))
                    }
                    .shadow(color: SpatialVideoTheme.accent.opacity(0.3), radius: 18, y: 7)
                    .accessibilityIdentifier("youtube.signIn")
                }

                if !session.authSession.isOAuthConfigured {
                    Label(
                        "Google OAuth needs to be configured in the app build.",
                        systemImage: "wrench.and.screwdriver.fill"
                    )
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                }
                if let error = session.authSession.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Button {
                    session.selectedSection = .downloads
                } label: {
                    Label("Open Downloads", systemImage: "internaldrive.fill")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(width: 240, height: 40)
                }
                .buttonStyle(.bordered)
                .tint(SpatialVideoTheme.accentSoft)
                .accessibilityIdentifier("youtube.openDownloads")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .background(SpatialVideoTheme.panel.opacity(0.78), in: RoundedRectangle(cornerRadius: 24))
            .overlay {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(SpatialVideoTheme.line)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var offlineDownloadsView: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                SpatialVideoAppMark(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloads")
                        .font(.headline)
                    Text("Available without a Google account")
                        .font(.caption)
                        .foregroundStyle(SpatialVideoTheme.muted)
                }
                Spacer()
                Button {
                    session.selectedSection = .subscriptions
                } label: {
                    Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(SpatialVideoTheme.accentSoft)
            }
            .padding(12)
            .background(SpatialVideoTheme.panel.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(SpatialVideoTheme.line) }

            downloadList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var signedInHeader: some View {
        HStack(spacing: 12) {
            SpatialVideoAppMark(size: 36)
            AsyncImage(url: session.authSession.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(session.authSession.accountLabel)
                    .font(.headline)
                    .lineLimit(1)
                if let email = session.authSession.email,
                   email != session.authSession.accountLabel {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Switch Account", systemImage: "person.2.fill") {
                session.switchAccount()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(SpatialVideoTheme.accentSoft)
            .disabled(session.authSession.isAuthorizing)
            .accessibilityIdentifier("youtube.switchAccount")
            Button("Refresh", systemImage: "arrow.clockwise") {
                session.loadLibrary()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.white)
            .disabled(session.isLoadingLibrary)
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                session.authSession.signOut()
                session.authorizationDidChange()
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(SpatialVideoTheme.muted)
        }
        .padding(12)
        .background(SpatialVideoTheme.panel.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(SpatialVideoTheme.line) }
    }

    @ViewBuilder
    private var libraryContent: some View {
        HStack(spacing: 8) {
            TextField("Search YouTube", text: $session.query)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(SpatialVideoTheme.panelStrong.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SpatialVideoTheme.line) }
                .onSubmit { session.submitSearch() }
                .accessibilityIdentifier("youtube.search")
            Button("Search", systemImage: "magnifyingglass") { session.submitSearch() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .tint(SpatialVideoTheme.accent)
        }

        if !session.results.isEmpty {
            HStack {
                Text("Search Results").font(.title3.bold())
                Spacer()
                Button("Clear", systemImage: "xmark.circle") { session.clearSearch() }
            }
            videoGrid(session.results)
        } else if let collectionTitle = session.collectionTitle {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Back", systemImage: "chevron.backward") { session.closeCollection() }
                    Text(collectionTitle).font(.title3.bold()).lineLimit(1)
                    Spacer()
                }
                videoGrid(
                    session.collectionVideos,
                    showsEmptyState: !session.isLoadingCollection && session.collectionErrorMessage == nil
                )
            }
        } else {
            Picker("YouTube Library", selection: $session.selectedSection) {
                ForEach(YouTubeBrowseSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .tint(SpatialVideoTheme.accent)
            .accessibilityIdentifier("youtube.librarySection")

            Group {
                switch session.selectedSection {
                case .subscriptions:
                    subscriptionList
                case .liked:
                    videoGrid(
                        session.likedVideos,
                        showsEmptyState: !session.isLoading(.liked)
                            && session.libraryErrorMessage(for: .liked) == nil
                    )
                case .library:
                    playlistGrid
                case .downloads:
                    downloadList
                }
            }
        }

        if session.isLoadingDisplayedLibraryContent {
            ProgressView().controlSize(.small)
        }
        if let error = session.displayedLibraryErrorMessage {
            VStack(spacing: 8) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    if session.selectedSection == .downloads, session.collectionTitle == nil {
                        Button("Dismiss", systemImage: "xmark") {
                            session.downloadStore.clearError()
                        }
                    } else {
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            if session.collectionTitle == nil {
                                session.loadLibrary()
                            } else {
                                session.closeCollection()
                            }
                        }
                        Button("Switch Account", systemImage: "person.2.fill") {
                            session.switchAccount()
                        }
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
        }
    }

    private var subscriptionList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(session.subscriptions) { subscription in
                    Button { session.open(subscription: subscription) } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: subscription.thumbnailURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.white.opacity(0.08)
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())

                            Text(subscription.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "chevron.forward")
                                .font(.caption.bold())
                                .foregroundStyle(SpatialVideoTheme.muted)
                        }
                        .padding(10)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(SpatialVideoTheme.line) }
                    }
                    .buttonStyle(.plain)
                }

                if session.subscriptions.isEmpty,
                   !session.isLoading(.subscriptions),
                   session.libraryErrorMessage(for: .subscriptions) == nil {
                    YouTubeEmptyLibraryView(title: "No subscriptions", systemImage: "rectangle.stack.badge.play")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var playlistGrid: some View {
        ScrollView {
            LazyVGrid(columns: cardColumns, spacing: 12) {
                ForEach(session.playlists) { playlist in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { session.open(playlist: playlist) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                YouTubeThumbnail(url: playlist.thumbnailURL)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                Text(playlist.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                Text("\(playlist.itemCount) videos")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Link(destination: playlist.youtubeURL) {
                            Label("Open in YouTube", systemImage: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .accessibilityIdentifier("youtube.openPlaylist.\(playlist.id)")
                    }
                    .padding(9)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(SpatialVideoTheme.line) }
                }

                if session.playlists.isEmpty,
                   !session.isLoading(.library),
                   session.libraryErrorMessage(for: .library) == nil {
                    YouTubeEmptyLibraryView(title: "No playlists", systemImage: "books.vertical")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func videoGrid(
        _ videos: [YouTubeVideo],
        showsEmptyState: Bool = true
    ) -> some View {
        ScrollView {
            LazyVGrid(columns: cardColumns, spacing: 12) {
                ForEach(videos) { video in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { session.load(video: video) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                YouTubeThumbnail(url: video.thumbnailURL)
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                Text(video.title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(2)
                                Text(video.channelTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        HStack {
                            if let activity = session.downloadStore.activity(for: video.id) {
                                YouTubeDownloadProgressView(
                                    activity: activity,
                                    resolution: session.downloadStore.pendingDownloads
                                        .first(where: { $0.id == video.id })?
                                        .resolution
                                )
                            } else if session.downloadStore.contains(videoID: video.id) {
                                Label("Downloaded", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Button {
                                    session.download(video)
                                } label: {
                                    Label(
                                        "Download · \(session.downloadStore.selectedQuality.title)",
                                        systemImage: "arrow.down.circle"
                                    )
                                        .font(.caption2.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(SpatialVideoTheme.accent)
                                .accessibilityIdentifier("youtube.download.\(video.id)")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(9)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(SpatialVideoTheme.line) }
                }

                if videos.isEmpty, showsEmptyState {
                    YouTubeEmptyLibraryView(title: "No videos", systemImage: "play.slash")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var downloadList: some View {
        VStack(spacing: 10) {
            HStack {
                Label(
                    "\(session.downloadStore.downloads.count) on device",
                    systemImage: "internaldrive.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(SpatialVideoTheme.muted)

                Spacer()

                Picker(
                    "Download Quality",
                    selection: Binding(
                        get: { session.downloadStore.selectedQuality },
                        set: { session.downloadStore.selectedQuality = $0 }
                    )
                ) {
                    ForEach(YouTubeDownloadQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .tint(SpatialVideoTheme.accentSoft)
                .accessibilityIdentifier("youtube.downloadQuality")

                Button {
                    isImportingVideo = true
                } label: {
                    Label("Import Video", systemImage: "square.and.arrow.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(SpatialVideoTheme.accent)
                .accessibilityIdentifier("youtube.importVideo")
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(session.downloadStore.pendingDownloads) { pending in
                        HStack(spacing: 12) {
                            YouTubeThumbnail(url: pending.thumbnailURL)
                                .frame(width: 112, height: 63)

                            VStack(alignment: .leading, spacing: 7) {
                                Text(pending.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                if let activity = session.downloadStore.activity(for: pending.id) {
                                    YouTubeDownloadProgressView(
                                        activity: activity,
                                        resolution: pending.resolution
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(10)
                        .background(SpatialVideoTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(SpatialVideoTheme.accentSoft.opacity(0.3))
                        }
                    }

                    ForEach(session.downloadStore.downloads) { download in
                        HStack(spacing: 10) {
                            Button {
                                session.load(download: download)
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        YouTubeThumbnail(url: download.thumbnailURL)
                                        if download.thumbnailURL == nil {
                                            Image(systemName: "film.fill")
                                                .font(.title2)
                                                .foregroundStyle(SpatialVideoTheme.muted)
                                        }
                                    }
                                    .frame(width: 112, height: 63)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(download.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(2)
                                        Text(download.channelTitle)
                                            .font(.caption)
                                            .foregroundStyle(SpatialVideoTheme.muted)
                                            .lineLimit(1)
                                        if let resolution = download.resolution {
                                            Text("\(resolution)p")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(SpatialVideoTheme.accentSoft)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(SpatialVideoTheme.accentSoft)
                                }
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                session.delete(download)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Delete \(download.title)")
                        }
                        .padding(10)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(SpatialVideoTheme.line) }
                    }

                    if session.downloadStore.downloads.isEmpty,
                       session.downloadStore.pendingDownloads.isEmpty {
                        ContentUnavailableView(
                            "No Downloads",
                            systemImage: "arrow.down.circle",
                            description: Text("Download a YouTube video or import one from Files.")
                        )
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)]
    }
}

private struct YouTubeDownloadProgressView: View {
    let activity: YouTubeDownloadActivity
    let resolution: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if activity.progress == nil {
                    ProgressView().controlSize(.mini)
                }
                Text(activity.title)
                    .font(.caption2.weight(.semibold))
                if let resolution {
                    Text("· \(resolution)p")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SpatialVideoTheme.accentSoft)
                }
                Spacer(minLength: 0)
                if let byteDetail = activity.byteDetail {
                    Text(byteDetail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(SpatialVideoTheme.muted)
                        .lineLimit(1)
                }
            }

            if let progress = activity.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(SpatialVideoTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct YouTubeThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.white.opacity(0.08)
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct YouTubeEmptyLibraryView: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(width: 240)
    }
}

struct YouTubeSpatialPanelView: View {
    let key: String
    @Bindable var session: YouTubeSession

    var body: some View {
        Group {
            switch key {
            case "youtube.video": YouTubeSurfaceView(session: session)
            case "youtube.info": YouTubeInfoPanel(session: session)
            case "youtube.search": YouTubeSearchPanel(session: session)
            case "youtube.transport": YouTubeTransportPanel(session: session)
            default: ContentUnavailableView("Unknown panel", systemImage: "questionmark.app")
            }
        }
        .task(id: session.authSession.isSignedIn) {
            session.authorizationDidChange()
        }
    }
}

private struct YouTubeInfoPanel: View {
    @Bindable var session: YouTubeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("NOW PLAYING", systemImage: "info.circle")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(SpatialVideoTheme.muted)

            if let download = session.currentDownload {
                AsyncImage(url: download.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "internaldrive.fill")
                            .font(.title)
                            .foregroundStyle(SpatialVideoTheme.muted)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(SpatialVideoTheme.line) }

                Label("On Device", systemImage: "internaldrive.fill")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(SpatialVideoTheme.accentSoft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(SpatialVideoTheme.accent.opacity(0.14), in: Capsule())

                Text(download.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(4)
                Text(download.channelTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(SpatialVideoTheme.muted)
            } else if let video = session.currentVideo {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.white.opacity(0.08) }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(SpatialVideoTheme.line) }

                Label("YouTube", systemImage: "play.rectangle.fill")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(SpatialVideoTheme.accentSoft)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(SpatialVideoTheme.accent.opacity(0.14), in: Capsule())

                Text(video.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .lineLimit(4)
                Text(video.channelTitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(SpatialVideoTheme.muted)
            } else {
                Spacer()
                Image(systemName: "circle.slash")
                    .font(.system(size: 45, weight: .light))
                    .foregroundStyle(SpatialVideoTheme.muted.opacity(0.62))
                    .frame(maxWidth: .infinity)
                Text("Nothing playing")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                Text("Choose a result from your library.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(SpatialVideoTheme.muted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            Spacer()
            if let error = session.playerErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Label(
                session.playerErrorMessage != nil ? "Unavailable" : session.isPlaying ? "Playing" : session.isReady ? "Paused" : "Loading",
                systemImage: session.playerErrorMessage != nil ? "exclamationmark.circle" : session.isPlaying ? "waveform" : "pause.circle"
            )
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(session.isPlaying ? .green : SpatialVideoTheme.muted)
        }
        .padding(20)
        .foregroundStyle(.white)
        .background(SpatialVideoTheme.panel)
    }
}

private struct YouTubeSearchPanel: View {
    @Bindable var session: YouTubeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("LIBRARY", systemImage: "books.vertical.fill")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(SpatialVideoTheme.muted)
            Text("Find your next video")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SpatialVideoTheme.muted)
                Text(session.query.isEmpty ? "Type on iPhone keyboard" : session.query)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if !session.query.isEmpty { Image(systemName: "xmark.circle.fill") }
            }
            .padding(12)
            .font(.system(size: 11, design: .rounded))
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SpatialVideoTheme.line) }
            if session.isSearching { ProgressView().frame(maxWidth: .infinity) }
            if let error = session.searchErrorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(session.results.prefix(5)) { video in
                        HStack(spacing: 10) {
                            AsyncImage(url: video.thumbnailURL) { image in image.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
                                .frame(width: 92, height: 52).clipped()
                            VStack(alignment: .leading, spacing: 3) {
                                Text(video.title).font(.caption.bold()).lineLimit(2)
                                Text(video.channelTitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(7)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SpatialVideoTheme.line.opacity(0.7)) }
                    }
                }
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .background(SpatialVideoTheme.panel)
    }
}

private struct YouTubeTransportPanel: View {
    @Bindable var session: YouTubeSession

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.currentDownload?.title ?? session.currentVideo?.title ?? "Choose a video")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(session.currentDownload?.channelTitle ?? session.currentVideo?.channelTitle ?? "Spatial Video")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(SpatialVideoTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "gobackward.10")
                    .frame(width: 32)
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(SpatialVideoTheme.accent, in: Circle())
                    .shadow(color: SpatialVideoTheme.accent.opacity(0.34), radius: 12)
                Image(systemName: "goforward.10")
                    .frame(width: 32)

                Text("\(format(session.currentTime)) / \(format(session.duration))")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SpatialVideoTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 5)
                    Capsule().fill(SpatialVideoTheme.accent).frame(width: proxy.size.width * progress, height: 5)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .foregroundStyle(.white)
        .background(SpatialVideoTheme.panel)
    }

    private var progress: CGFloat {
        guard session.duration > 0 else { return 0 }
        return CGFloat((session.currentTime / session.duration).clamped(to: 0 ... 1))
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

#if DEBUG
#Preview("YouTube Spatial Panels") {
    let session = YouTubeSession(initialVideoID: nil, loadsContent: false)
    return HStack {
        YouTubeInfoPanel(session: session)
        YouTubeSearchPanel(session: session)
        YouTubeTransportPanel(session: session)
    }
    .frame(width: 1_200, height: 420)
    .preferredColorScheme(.dark)
}
#endif
