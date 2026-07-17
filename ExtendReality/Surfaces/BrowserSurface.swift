import Observation
import SwiftUI
import WebKit

@MainActor
private final class BrowserDataMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: BrowserSession?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard let session else {
            replyHandler(nil, "The ExtendReality host is no longer available.")
            return
        }
        session.handleHostDataMessage(message, replyHandler: replyHandler)
    }
}

@MainActor
@Observable
final class BrowserSession: NSObject, InputTarget, WKNavigationDelegate, WKUIDelegate {
    var address: String
    private(set) var title = "Browser"
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let navigationPolicy: PWAOriginPolicy?
    @ObservationIgnored private let capabilityProvider: (PWACapability) -> Bool
    @ObservationIgnored private let dataProvider: ((PWACapability) throws -> [String: Any])?
    @ObservationIgnored private let dataMessageHandler: BrowserDataMessageHandler?

    private static let dataMessageHandlerName = "extendRealityData"

    init(
        initialURL: String,
        loadsContent: Bool = true,
        websiteDataStore: WKWebsiteDataStore = .default(),
        navigationPolicy: PWAOriginPolicy? = nil,
        capabilityProvider: @escaping (PWACapability) -> Bool = { _ in false },
        dataProvider: ((PWACapability) throws -> [String: Any])? = nil
    ) {
        address = initialURL
        self.navigationPolicy = navigationPolicy
        self.capabilityProvider = capabilityProvider
        self.dataProvider = dataProvider
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = websiteDataStore
        let dataMessageHandler: BrowserDataMessageHandler?
        if navigationPolicy != nil, dataProvider != nil {
            let handler = BrowserDataMessageHandler()
            dataMessageHandler = handler
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Self.hostAPIScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            configuration.userContentController.addScriptMessageHandler(
                handler,
                contentWorld: .page,
                name: Self.dataMessageHandlerName
            )
        } else {
            dataMessageHandler = nil
        }
        self.dataMessageHandler = dataMessageHandler
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        dataMessageHandler?.session = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let navigationPolicy,
              let url = navigationAction.request.url else {
            return .allow
        }
        guard navigationPolicy.allowsTopLevelNavigation(to: url) else {
            if navigationAction.navigationType == .linkActivated,
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                await UIApplication.shared.open(url)
            }
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
        initiatedBy frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        guard navigationPolicy != nil else {
            return .prompt
        }
        let granted: Bool
        switch type {
        case .camera:
            granted = capabilityProvider(.camera)
        case .microphone:
            granted = capabilityProvider(.microphone)
        case .cameraAndMicrophone:
            granted = capabilityProvider(.camera) && capabilityProvider(.microphone)
        @unknown default:
            granted = false
        }
        return granted ? .grant : .deny
    }

    fileprivate func handleHostDataMessage(
        _ message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard message.name == Self.dataMessageHandlerName,
              message.frameInfo.isMainFrame,
              navigationPolicy != nil,
              let dataProvider,
              let rawCapability = message.body as? String,
              let capability = PWACapability(rawValue: rawCapability),
              [.location, .health, .focusStatus].contains(capability) else {
            replyHandler(nil, "Invalid ExtendReality host API request.")
            return
        }
        guard capabilityProvider(capability) else {
            replyHandler(nil, "The app has not been granted \(capability.title) access.")
            return
        }

        do {
            replyHandler(try dataProvider(capability), nil)
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
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

    private static let hostAPIScript = """
        (() => {
          const handler = window.webkit?.messageHandlers?.extendRealityData;
          if (!handler || window.extendReality) return;
          const read = capability => handler.postMessage(capability);
          Object.defineProperty(window, 'extendReality', {
            value: Object.freeze({
              version: 2,
              getLocation: () => read('location'),
              getHealthSummary: () => read('health'),
              getFocusStatus: () => read('focusStatus')
            }),
            configurable: false,
            writable: false
          });
        })();
        """
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
