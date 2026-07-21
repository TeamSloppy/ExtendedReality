import Observation
import SwiftUI
import WebKit

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
    private(set) var currentVideo: YouTubeVideo?
    private(set) var results: [YouTubeVideo] = []
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
    @ObservationIgnored private var apiClient: YouTubeAPIClient?
    @ObservationIgnored private var apiKeyProvider: () -> String = { "" }
    @ObservationIgnored private let playerOrigin: URL
    @ObservationIgnored private let textInputFocusHandler: () -> Void
    @ObservationIgnored private let playbackStateDidChange: () -> Void

    init(
        initialVideoID: String?,
        loadsContent: Bool = true,
        appIdentifier: String? = Bundle.main.bundleIdentifier,
        textInputFocusHandler: @escaping () -> Void = {},
        playbackStateDidChange: @escaping () -> Void = {}
    ) {
        videoID = initialVideoID
        self.textInputFocusHandler = textInputFocusHandler
        self.playbackStateDidChange = playbackStateDidChange
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

    func configureSearch(apiClient: YouTubeAPIClient, apiKeyProvider: @escaping () -> String) {
        self.apiClient = apiClient
        self.apiKeyProvider = apiKeyProvider
        if let videoID, currentVideo == nil { loadMetadata(for: videoID) }
    }

    func load(_ value: String) {
        guard let parsed = YouTubeVideoIDParser.parse(value) else { return }
        videoID = parsed
        currentVideo = nil
        results = []
        loadPlayer(videoID: parsed)
        loadMetadata(for: parsed)
    }

    func load(video: YouTubeVideo) {
        videoID = video.id
        currentVideo = video
        loadPlayer(videoID: video.id)
    }

    func submitSearch() {
        searchErrorMessage = nil
        if YouTubeVideoIDParser.parse(query) != nil {
            load(query)
            return
        }
        guard let apiClient else {
            searchErrorMessage = YouTubeAPIError.missingCredentials.localizedDescription
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
                let found = try await apiClient.search(query: submittedQuery, apiKey: apiKeyProvider())
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
        webView.evaluateJavaScript("player && player.playVideo();")
    }

    func pause() {
        webView.evaluateJavaScript("player && player.pauseVideo();")
    }

    func seek(seconds: Double) {
        webView.evaluateJavaScript("player && player.seekTo(Math.max(0, player.getCurrentTime() + \(seconds)), true);")
    }

    func seek(to time: Double) {
        guard time.isFinite else { return }
        webView.evaluateJavaScript("player && player.seekTo(\(max(0, time)), true);")
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
        case .pointerUp(let position) where panelID == "search":
            handleSearchClick(at: position)
        case .pointerUp(let position) where panelID == "transport":
            handleTransportClick(at: position)
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
                textInputFocusHandler()
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
        guard let apiClient else { return }
        let apiKey = apiKeyProvider()
        guard !apiKey.isEmpty else { return }
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            guard let self else { return }
            do {
                let video = try await apiClient.video(id: videoID, apiKey: apiKey)
                guard !Task.isCancelled, self.videoID == videoID else { return }
                currentVideo = video
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private func loadPlayer(videoID: String?) {
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

struct YouTubeSurfaceView: UIViewRepresentable {
    let session: YouTubeSession

    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct YouTubeSpatialPanelView: View {
    let key: String
    @Bindable var session: YouTubeSession
    let apiClient: YouTubeAPIClient
    @AppStorage("youtube.apiKey") private var apiKey = ""

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
        .onAppear {
            session.configureSearch(apiClient: apiClient, apiKeyProvider: { apiKey })
        }
    }
}

private struct YouTubeInfoPanel: View {
    @Bindable var session: YouTubeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let video = session.currentVideo {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.white.opacity(0.08) }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                Text(video.title).font(.title3.bold()).lineLimit(4)
                Text(video.channelTitle).font(.headline).foregroundStyle(.secondary)
            } else {
                Image(systemName: "play.rectangle.fill").font(.system(size: 44)).foregroundStyle(.red)
                Text(session.videoID == nil ? "Choose a video" : "Now playing")
                    .font(.title2.bold())
                Text(session.videoID ?? "Search from the panel on the right")
                    .font(.body.monospaced()).foregroundStyle(.secondary)
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
                .foregroundStyle(session.isPlaying ? .green : .secondary)
        }
        .padding(22)
        .background(.ultraThinMaterial)
    }
}

private struct YouTubeSearchPanel: View {
    @Bindable var session: YouTubeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                Text(session.query.isEmpty ? "Type on iPhone keyboard" : session.query)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if !session.query.isEmpty { Image(systemName: "xmark.circle.fill") }
            }
            .padding(12)
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
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
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }
}

private struct YouTubeTransportPanel: View {
    @Bindable var session: YouTubeSession

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "gobackward.10")
                Spacer()
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2).frame(width: 72)
                Spacer()
                Image(systemName: "goforward.10")
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 5)
                    Capsule().fill(.red).frame(width: proxy.size.width * progress, height: 5)
                }
            }
            .frame(height: 5)
            HStack {
                Text(format(session.currentTime))
                Spacer()
                Text(format(session.duration))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
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
