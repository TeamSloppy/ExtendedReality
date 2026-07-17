import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class BrowserSession: NSObject, InputTarget, WKNavigationDelegate {
    var address: String
    private(set) var title = "Browser"
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored let webView: WKWebView

    init(initialURL: String, loadsContent: Bool = true) {
        address = initialURL
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        if loadsContent {
            load(initialURL)
        }
    }

    func load(_ rawValue: String? = nil) {
        let raw = (rawValue ?? address).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let resolved: String
        if raw.contains("://") {
            resolved = raw
        } else if raw.contains(".") && !raw.contains(" ") {
            resolved = "https://\(raw)"
        } else {
            let query = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
            resolved = "https://www.google.com/search?q=\(query)"
        }
        address = resolved
        guard let url = URL(string: resolved) else { return }
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    func handle(_ command: InputCommand) {
        switch command {
        case .pointerMoved(let position):
            updateCursor(position)
        case .pointerDown(let position):
            dispatchPointerEvent("pointerdown", at: position)
        case .pointerUp(let position):
            dispatchPointerEvent("pointerup", at: position, click: true)
        case .scroll(let delta):
            webView.evaluateJavaScript("window.scrollBy(\(delta.dx * 900), \(delta.dy * 900));")
        case .insertText(let text):
            let literal = Self.javaScriptLiteral(text)
            webView.evaluateJavaScript("""
                (() => {
                  const e = document.activeElement;
                  if (!e) return;
                  if (typeof e.value === 'string') {
                    e.value += \(literal);
                    e.dispatchEvent(new Event('input', { bubbles: true }));
                  }
                })();
                """)
        case .back:
            if webView.canGoBack { webView.goBack() }
        case .media:
            break
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isLoading = false
        address = webView.url?.absoluteString ?? address
        title = webView.title ?? "Browser"
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        installCursor()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        isLoading = false
    }

    private func installCursor() {
        webView.evaluateJavaScript("""
            (() => {
              if (document.getElementById('__extendRealityCursor')) return;
              const c = document.createElement('div');
              c.id = '__extendRealityCursor';
              c.style.cssText = 'position:fixed;width:14px;height:14px;border-radius:50%;background:white;border:1px solid rgba(0,0,0,.5);z-index:2147483647;pointer-events:none;left:50%;top:50%;transform:translate(-50%,-50%)';
              document.documentElement.appendChild(c);
            })();
            """)
    }

    private func updateCursor(_ position: CGPoint) {
        installCursor()
        webView.evaluateJavaScript("""
            (() => { const c = document.getElementById('__extendRealityCursor'); if(c){ c.style.left='\(position.x * 100)%'; c.style.top='\(position.y * 100)%'; } })();
            """)
    }

    private func dispatchPointerEvent(_ name: String, at position: CGPoint, click: Bool = false) {
        let x = position.x * webView.bounds.width
        let y = position.y * webView.bounds.height
        webView.evaluateJavaScript("""
            (() => {
              const e = document.elementFromPoint(\(x), \(y));
              if (!e) return;
              e.dispatchEvent(new PointerEvent('\(name)', { bubbles:true, clientX:\(x), clientY:\(y), pointerType:'mouse' }));
              \(click ? "if (typeof e.click === 'function') e.click();" : "")
            })();
            """)
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let result = String(data: data, encoding: .utf8) else { return "\"\"" }
        return result
    }
}

struct BrowserSurfaceView: UIViewRepresentable {
    let session: BrowserSession

    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#if DEBUG
#Preview("Browser Surface") {
    BrowserSurfaceView(
        session: BrowserSession(initialURL: "about:blank", loadsContent: false)
    )
    .frame(width: 960, height: 540)
}
#endif
