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
private final class BrowserWindowMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
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
        session.handleSpatialWindowMessage(message, replyHandler: replyHandler)
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
    private(set) var lastErrorMessage: String?
    private(set) var hasLoadedRequest = false
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let navigationPolicy: PWAOriginPolicy?
    @ObservationIgnored private let capabilityProvider: (PWACapability) -> Bool
    @ObservationIgnored private let dataProvider: ((PWACapability) throws -> [String: Any])?
    @ObservationIgnored private let dataMessageHandler: BrowserDataMessageHandler?
    @ObservationIgnored private let windowMessageHandler: BrowserWindowMessageHandler?
    @ObservationIgnored private let spatialWindowClient: SpatialWindowClient?
    @ObservationIgnored private let textInputFocusHandler: (String) -> Void
    @ObservationIgnored private var cursorPosition = CGPoint(x: 0.5, y: 0.5)
    @ObservationIgnored var newWindowHandler: ((URLRequest) -> Void)?

    private static let dataMessageHandlerName = "extendRealityData"
    private static let windowMessageHandlerName = "extendRealityWindows"

    init(
        initialURL: String,
        loadsContent: Bool = true,
        websiteDataStore: WKWebsiteDataStore = .default(),
        navigationPolicy: PWAOriginPolicy? = nil,
        capabilityProvider: @escaping (PWACapability) -> Bool = { _ in false },
        dataProvider: ((PWACapability) throws -> [String: Any])? = nil,
        spatialWindowClient: SpatialWindowClient? = nil,
        textInputFocusHandler: @escaping (String) -> Void = { _ in }
    ) {
        address = initialURL
        self.navigationPolicy = navigationPolicy
        self.capabilityProvider = capabilityProvider
        self.dataProvider = dataProvider
        self.spatialWindowClient = spatialWindowClient
        self.textInputFocusHandler = textInputFocusHandler
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = websiteDataStore
        let dataMessageHandler: BrowserDataMessageHandler?
        let windowMessageHandler: BrowserWindowMessageHandler?
        if navigationPolicy != nil, dataProvider != nil {
            let handler = BrowserDataMessageHandler()
            dataMessageHandler = handler
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Self.hostAPIScript(includesWindowAPI: spatialWindowClient != nil),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            configuration.userContentController.addScriptMessageHandler(
                handler,
                contentWorld: .page,
                name: Self.dataMessageHandlerName
            )
            if spatialWindowClient != nil {
                let windowHandler = BrowserWindowMessageHandler()
                windowMessageHandler = windowHandler
                configuration.userContentController.addScriptMessageHandler(
                    windowHandler,
                    contentWorld: .page,
                    name: Self.windowMessageHandlerName
                )
            } else {
                windowMessageHandler = nil
            }
        } else {
            dataMessageHandler = nil
            windowMessageHandler = nil
        }
        self.dataMessageHandler = dataMessageHandler
        self.windowMessageHandler = windowMessageHandler
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        dataMessageHandler?.session = self
        windowMessageHandler?.session = self
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
        guard let url = BrowserURLResolver.resolve(raw) else {
            lastErrorMessage = "Enter a valid web address or search query."
            return
        }
        load(URLRequest(url: url))
    }

    func load(_ request: URLRequest) {
        guard let url = request.url else { return }
        address = url.absoluteString
        lastErrorMessage = nil
        hasLoadedRequest = true
        webView.load(request)
    }

    func reload() {
        if webView.url == nil {
            load()
        } else {
            webView.reload()
        }
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
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
            dispatchWheelEvent(
                deltaX: Double(delta.dx * 900),
                deltaY: Double(delta.dy * 900),
                at: cursorPosition,
                ctrlKey: false,
                scrollsPageWhenUnhandled: true
            )
        case .magnify(let scaleDelta, let position):
            dispatchMagnifyEvent(scaleDelta: scaleDelta, at: position)
        case .insertText(let text):
            let literal = Self.javaScriptLiteral(text)
            webView.evaluateJavaScript("""
                (() => {
                  let e = document.activeElement;
                  while (e?.shadowRoot?.activeElement) e = e.shadowRoot.activeElement;
                  if (!e) return;
                  if (typeof e.value === 'string') {
                    const start = Number.isInteger(e.selectionStart) ? e.selectionStart : e.value.length;
                    const end = Number.isInteger(e.selectionEnd) ? e.selectionEnd : start;
                    const nextValue = e.value.slice(0, start) + \(literal) + e.value.slice(end);
                    const prototype = e instanceof HTMLTextAreaElement
                      ? HTMLTextAreaElement.prototype
                      : HTMLInputElement.prototype;
                    const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
                    if (setter) setter.call(e, nextValue); else e.value = nextValue;
                    e.setSelectionRange?.(start + \(literal).length, start + \(literal).length);
                    e.dispatchEvent(new InputEvent('input', {
                      bubbles: true,
                      inputType: 'insertText',
                      data: \(literal)
                    }));
                  } else if (e.isContentEditable) {
                    document.execCommand('insertText', false, \(literal));
                  }
                })();
                """)
        case .replaceText(let text):
            replaceActiveText(with: text, submits: false)
        case .submitText(let text):
            replaceActiveText(with: text, submits: true)
        case .back:
            if webView.canGoBack { webView.goBack() }
        case .media:
            break
        }
    }

    private func replaceActiveText(with text: String, submits: Bool) {
        let literal = Self.javaScriptLiteral(text)
        webView.evaluateJavaScript("""
            (() => {
              let e = document.activeElement;
              while (e?.shadowRoot?.activeElement) e = e.shadowRoot.activeElement;
              if (!e) return false;
              const value = \(literal);
              if (typeof e.value === 'string') {
                const prototype = e instanceof HTMLTextAreaElement
                  ? HTMLTextAreaElement.prototype
                  : HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
                if (setter) setter.call(e, value); else e.value = value;
                e.setSelectionRange?.(value.length, value.length);
              } else if (e.isContentEditable) {
                e.textContent = value;
              } else {
                return false;
              }
              e.dispatchEvent(new InputEvent('input', {
                bubbles: true,
                inputType: 'insertReplacementText',
                data: null
              }));
              if (\(submits)) {
                e.dispatchEvent(new Event('change', { bubbles: true }));
                const options = {
                  key: 'Enter',
                  code: 'Enter',
                  keyCode: 13,
                  which: 13,
                  bubbles: true,
                  cancelable: true
                };
                const shouldSubmit = e.dispatchEvent(new KeyboardEvent('keydown', options));
                e.dispatchEvent(new KeyboardEvent('keypress', options));
                e.dispatchEvent(new KeyboardEvent('keyup', options));
                if (shouldSubmit && e.form) {
                  if (typeof e.form.requestSubmit === 'function') e.form.requestSubmit();
                  else e.form.submit();
                }
              }
              return true;
            })();
            """)
    }

    private func dispatchMagnifyEvent(scaleDelta: CGFloat, at position: CGPoint) {
        let scale = Double(scaleDelta).clamped(to: 0.25 ... 4)
        dispatchWheelEvent(
            deltaX: 0,
            deltaY: -log(scale) * 300,
            at: position,
            ctrlKey: true,
            scrollsPageWhenUnhandled: false
        )
    }

    private func dispatchWheelEvent(
        deltaX: Double,
        deltaY: Double,
        at position: CGPoint,
        ctrlKey: Bool,
        scrollsPageWhenUnhandled: Bool
    ) {
        let x = Double(position.x.clamped(to: 0 ... 1))
        let y = Double(position.y.clamped(to: 0 ... 1))
        webView.evaluateJavaScript("""
            (() => {
              const x = \(x) * window.innerWidth;
              const y = \(y) * window.innerHeight;
              const elementAtPoint = root => {
                const hit = root.elementFromPoint?.(x, y);
                if (!hit) return null;
                return hit.shadowRoot ? elementAtPoint(hit.shadowRoot) ?? hit : hit;
              };
              const target = elementAtPoint(document) || document.scrollingElement || document.body;
              const unhandled = target?.dispatchEvent(new WheelEvent('wheel', {
                bubbles: true,
                cancelable: true,
                clientX: x,
                clientY: y,
                deltaX: \(deltaX),
                deltaY: \(deltaY),
                deltaMode: WheelEvent.DOM_DELTA_PIXEL,
                ctrlKey: \(ctrlKey)
              }));
              if (unhandled && \(scrollsPageWhenUnhandled)) {
                window.scrollBy(\(deltaX), \(deltaY));
              }
            })();
            """)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let newWindowHandler else { return nil }
        newWindowHandler(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        isLoading = true
        lastErrorMessage = nil
        spatialWindowClient?.resetLayout()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isLoading = false
        address = webView.url?.absoluteString ?? address
        title = webView.title ?? "Browser"
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        lastErrorMessage = nil
        installCursor()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        isLoading = false
        lastErrorMessage = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        isLoading = false
        lastErrorMessage = error.localizedDescription
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

    fileprivate func handleSpatialWindowMessage(
        _ message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard message.name == Self.windowMessageHandlerName,
              message.frameInfo.isMainFrame,
              let client = spatialWindowClient,
              let payload = message.body as? [String: Any],
              let operation = payload["operation"] as? String else {
            replyHandler(nil, "Invalid ExtendReality window request.")
            return
        }

        do {
            switch operation {
            case "setLayout":
                let layout = try spatialLayout(from: payload)
                try client.setLayout(layout)
                replyHandler(["panelCount": layout.panels.count], nil)
            case "create":
                try client.createPanel(spatialPanel(from: payload["panel"]))
                replyHandler(["ok": true], nil)
            case "update":
                try client.updatePanel(spatialPanel(from: payload["panel"]))
                replyHandler(["ok": true], nil)
            case "remove":
                guard let rawID = payload["id"] as? String else {
                    throw SpatialWindowError.invalidPanelIdentifier
                }
                try client.removePanel(SpatialPanelID(rawValue: rawID))
                replyHandler(["ok": true], nil)
            case "reset":
                client.resetLayout()
                replyHandler(["ok": true], nil)
            default:
                replyHandler(nil, "Unknown ExtendReality window operation.")
            }
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
        cursorPosition = position
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
              const elementAtPoint = root => {
                const hit = root.elementFromPoint?.(\(x), \(y));
                if (!hit) return null;
                return hit.shadowRoot ? elementAtPoint(hit.shadowRoot) ?? hit : hit;
              };
              const e = elementAtPoint(document);
              if (!e) return false;
              e.dispatchEvent(new PointerEvent('\(name)', { bubbles:true, clientX:\(x), clientY:\(y), pointerType:'mouse' }));
              \(click ? """
              if (typeof e.click === 'function') e.click();
              const editable = e.closest?.('textarea, [contenteditable]:not([contenteditable="false"]), input:not([type]), input[type="text"], input[type="search"], input[type="url"], input[type="email"], input[type="tel"], input[type="password"], input[type="number"]');
              if (!editable || editable.disabled || editable.readOnly) return false;
              editable.focus({ preventScroll: false });
              return typeof editable.value === 'string'
                ? editable.value
                : (editable.innerText ?? editable.textContent ?? '');
              """ : "return null;")
            })();
            """) { [weak self] value, _ in
                guard let text = value as? String else { return }
                self?.textInputFocusHandler(text)
            }
    }

    private static func javaScriptLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let result = String(data: data, encoding: .utf8) else { return "\"\"" }
        return result
    }

    private func spatialLayout(from payload: [String: Any]) throws -> SpatialAppLayout {
        guard let rawPanels = payload["panels"] as? [Any] else {
            throw SpatialWindowError.invalidPanelCount
        }
        let panels = try rawPanels.map(spatialPanel(from:))
        let primaryID = (payload["primaryPanelID"] as? String).map(SpatialPanelID.init(rawValue:)) ?? .primary
        return SpatialAppLayout(primaryPanelID: primaryID, panels: panels)
    }

    private func spatialPanel(from value: Any?) throws -> SpatialPanelDescriptor {
        guard let value = value as? [String: Any],
              let rawID = value["id"] as? String,
              let placement = value["placement"] as? [String: Any] else {
            throw SpatialWindowError.invalidPanelIdentifier
        }
        let id = SpatialPanelID(rawValue: rawID)
        let urlValue = value["url"] as? String
        let content: SpatialPanelContent
        if urlValue == nil, id == spatialWindowClient?.layout?.primaryPanelID ?? .primary {
            content = .primary
        } else if let urlValue,
                  let url = URL(string: urlValue, relativeTo: webView.url ?? URL(string: address))?.absoluteURL {
            content = .web(url)
        } else {
            content = .primary
        }
        return SpatialPanelDescriptor(
            id: id,
            accessibilityLabel: (value["accessibilityLabel"] as? String) ?? rawID,
            placement: SpatialPanelPlacement(
                yaw: Self.double(placement["yaw"]),
                pitch: Self.double(placement["pitch"]),
                depth: Self.double(placement["depth"]),
                width: Self.double(placement["width"]),
                height: Self.double(placement["height"]),
                layer: (placement["layer"] as? NSNumber)?.intValue ?? 0
            ),
            content: content
        )
    }

    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? .nan
    }

    private static func hostAPIScript(includesWindowAPI: Bool) -> String {
        let windows = includesWindowAPI
            ? """
              windows: Object.freeze({
                setLayout: value => mutate('setLayout', value),
                create: panel => mutate('create', { panel }),
                update: (id, changes) => mutate('update', { panel: Object.assign({}, changes, { id }) }),
                remove: id => mutate('remove', { id }),
                reset: () => mutate('reset', {})
              }),
            """
            : ""
        return """
        (() => {
          const handler = window.webkit?.messageHandlers?.extendRealityData;
          if (!handler || window.extendReality) return;
          const read = capability => handler.postMessage(capability);
          const windowHandler = window.webkit?.messageHandlers?.extendRealityWindows;
          const mutate = (operation, value) => {
            if (!windowHandler) return Promise.reject(new Error('Spatial window API unavailable'));
            return windowHandler.postMessage(Object.assign({ operation }, value || {}));
          };
          Object.defineProperty(window, 'extendReality', {
            value: Object.freeze({
              version: 3,
              getLocation: () => read('location'),
              getHealthSummary: () => read('health'),
              getFocusStatus: () => read('focusStatus'),
              \(windows)
            }),
            configurable: false,
            writable: false
          });
        })();
        """
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
