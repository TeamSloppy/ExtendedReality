import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class YouTubeSession: NSObject, InputTarget, WKNavigationDelegate {
    var videoID: String?
    private(set) var isReady = false
    private(set) var isPlaying = false
    @ObservationIgnored let webView: WKWebView

    init(initialVideoID: String?, loadsContent: Bool = true) {
        videoID = initialVideoID
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        if loadsContent {
            loadPlayer(videoID: initialVideoID)
        }
    }

    func load(_ value: String) {
        guard let parsed = YouTubeVideoIDParser.parse(value) else { return }
        videoID = parsed
        loadPlayer(videoID: parsed)
    }

    func load(video: YouTubeVideo) {
        videoID = video.id
        loadPlayer(videoID: video.id)
    }

    func play() {
        webView.evaluateJavaScript("player && player.playVideo();")
        isPlaying = true
    }

    func pause() {
        webView.evaluateJavaScript("player && player.pauseVideo();")
        isPlaying = false
    }

    func seek(seconds: Double) {
        webView.evaluateJavaScript("player && player.seekTo(Math.max(0, player.getCurrentTime() + \(seconds)), true);")
    }

    func handle(_ command: InputCommand) {
        switch command {
        case .media(let media):
            switch media {
            case .play: play()
            case .pause: pause()
            case .togglePlayback: isPlaying ? pause() : play()
            case .seek(let seconds): seek(seconds: seconds)
            }
        case .back:
            pause()
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isReady = true
    }

    private func loadPlayer(videoID: String?) {
        isReady = false
        let id = videoID ?? ""
        let html = """
            <!doctype html>
            <html><head>
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
            <style>html,body,#player{width:100%;height:100%;margin:0;background:#000;overflow:hidden}</style>
            </head><body><div id="player"></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
              var player;
              function onYouTubeIframeAPIReady(){
                player = new YT.Player('player', {
                  videoId: '\(id)',
                  playerVars: { playsinline: 1, controls: 1, rel: 0 },
                  events: { onReady: function(){ document.title='ready'; } }
                });
              }
            </script></body></html>
            """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }
}

struct YouTubeSurfaceView: UIViewRepresentable {
    let session: YouTubeSession

    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#if DEBUG
#Preview("YouTube Surface") {
    YouTubeSurfaceView(
        session: YouTubeSession(initialVideoID: nil, loadsContent: false)
    )
    .frame(width: 960, height: 540)
    .background(.black)
}
#endif
