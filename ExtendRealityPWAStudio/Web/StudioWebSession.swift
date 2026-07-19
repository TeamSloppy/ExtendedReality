import AppKit
import Observation
import WebKit

@MainActor
private final class StudioReplyMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    enum Kind {
        case data
        case windows
    }

    weak var session: StudioWebSession?
    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard let session else {
            replyHandler(nil, "The ExtendReality host is no longer available.")
            return
        }
        switch kind {
        case .data:
            session.handleDataMessage(message, replyHandler: replyHandler)
        case .windows:
            session.handleWindowMessage(message, replyHandler: replyHandler)
        }
    }
}

@MainActor
private final class StudioConsoleMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: StudioWebSession?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        session?.handleConsoleMessage(message)
    }
}

@MainActor
@Observable
final class StudioWebSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var title = "PWA"
    private(set) var currentURL: URL?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let isPrimary: Bool
    @ObservationIgnored private let capabilityProvider: (PWACapability) -> Bool
    @ObservationIgnored private let dataProvider: (PWACapability) throws -> [String: Any]
    @ObservationIgnored private let layoutProvider: () -> SpatialAppLayout
    @ObservationIgnored private let layoutHandler: (SpatialAppLayout?) throws -> Void
    @ObservationIgnored private let logHandler: (StudioLogLevel, String, String) -> Void
    @ObservationIgnored private var originPolicy: StudioOriginPolicy?
    @ObservationIgnored private let dataHandler: StudioReplyMessageHandler
    @ObservationIgnored private let windowHandler: StudioReplyMessageHandler?
    @ObservationIgnored private let consoleHandler: StudioConsoleMessageHandler

    init(
        isPrimary: Bool,
        websiteDataStore: WKWebsiteDataStore,
        capabilityProvider: @escaping (PWACapability) -> Bool,
        dataProvider: @escaping (PWACapability) throws -> [String: Any],
        layoutProvider: @escaping () -> SpatialAppLayout,
        layoutHandler: @escaping (SpatialAppLayout?) throws -> Void,
        logHandler: @escaping (StudioLogLevel, String, String) -> Void
    ) {
        self.isPrimary = isPrimary
        self.capabilityProvider = capabilityProvider
        self.dataProvider = dataProvider
        self.layoutProvider = layoutProvider
        self.layoutHandler = layoutHandler
        self.logHandler = logHandler

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = websiteDataStore

        let dataHandler = StudioReplyMessageHandler(kind: .data)
        self.dataHandler = dataHandler
        configuration.userContentController.addScriptMessageHandler(
            dataHandler,
            contentWorld: .page,
            name: Self.dataMessageHandlerName
        )

        if isPrimary {
            let windowHandler = StudioReplyMessageHandler(kind: .windows)
            self.windowHandler = windowHandler
            configuration.userContentController.addScriptMessageHandler(
                windowHandler,
                contentWorld: .page,
                name: Self.windowMessageHandlerName
            )
        } else {
            windowHandler = nil
        }

        let consoleHandler = StudioConsoleMessageHandler()
        self.consoleHandler = consoleHandler
        configuration.userContentController.add(
            consoleHandler,
            name: Self.consoleMessageHandlerName
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.hostAPIScript(includesWindowAPI: isPrimary),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        dataHandler.session = self
        windowHandler?.session = self
        consoleHandler.session = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
    }

    func load(_ url: URL) {
        currentURL = url
        originPolicy = try? StudioOriginPolicy(baseURL: url)
        errorMessage = nil
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        webView.load(request)
    }

    func reload() {
        if webView.url == nil, let currentURL {
            load(currentURL)
        } else {
            webView.reload()
        }
    }

    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        isLoading = true
        errorMessage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        isLoading = false
        currentURL = webView.url ?? currentURL
        title = webView.title ?? "PWA"
        errorMessage = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        recordFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        recordFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url,
              let originPolicy else {
            return .allow
        }
        guard originPolicy.allows(url) else {
            if navigationAction.navigationType == .linkActivated,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
            logHandler(.warning, "navigation", "Blocked external navigation to \(url.absoluteString)")
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
        let isGranted: Bool
        switch type {
        case .camera:
            isGranted = capabilityProvider(.camera)
        case .microphone:
            isGranted = capabilityProvider(.microphone)
        case .cameraAndMicrophone:
            isGranted = capabilityProvider(.camera) && capabilityProvider(.microphone)
        @unknown default:
            isGranted = false
        }
        return isGranted ? .grant : .deny
    }

    fileprivate func handleDataMessage(
        _ message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame,
              let rawCapability = message.body as? String,
              let capability = PWACapability(rawValue: rawCapability),
              [.location, .health, .focusStatus].contains(capability) else {
            replyHandler(nil, "Invalid ExtendReality host API request.")
            return
        }
        guard capabilityProvider(capability) else {
            replyHandler(nil, StudioHostError.permissionDenied(capability).localizedDescription)
            return
        }
        do {
            replyHandler(try dataProvider(capability), nil)
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }

    fileprivate func handleWindowMessage(
        _ message: WKScriptMessage,
        replyHandler: @escaping @MainActor (Any?, String?) -> Void
    ) {
        guard isPrimary,
              message.frameInfo.isMainFrame,
              capabilityProvider(.spatialWindows),
              let payload = message.body as? [String: Any],
              let operation = payload["operation"] as? String else {
            replyHandler(nil, "Spatial Windows permission is denied or the request is invalid.")
            return
        }

        do {
            switch operation {
            case "setLayout":
                let layout = try spatialLayout(from: payload)
                try layoutHandler(layout)
                replyHandler(["panelCount": layout.panels.count], nil)
            case "create":
                var layout = layoutProvider()
                let panel = try spatialPanel(from: payload["panel"], primaryPanelID: layout.primaryPanelID)
                guard !layout.panels.contains(where: { $0.id == panel.id }) else {
                    throw SpatialWindowError.invalidPanelIdentifier
                }
                layout.panels.append(panel)
                try layoutHandler(layout)
                replyHandler(["ok": true], nil)
            case "update":
                var layout = layoutProvider()
                let panel = try spatialPanel(from: payload["panel"], primaryPanelID: layout.primaryPanelID)
                guard let index = layout.panels.firstIndex(where: { $0.id == panel.id }) else {
                    throw SpatialWindowError.invalidPanelIdentifier
                }
                layout.panels[index] = panel
                try layoutHandler(layout)
                replyHandler(["ok": true], nil)
            case "remove":
                var layout = layoutProvider()
                guard let rawID = payload["id"] as? String else {
                    throw SpatialWindowError.invalidPanelIdentifier
                }
                let id = SpatialPanelID(rawValue: rawID)
                guard id != layout.primaryPanelID else {
                    throw SpatialWindowError.invalidPanelIdentifier
                }
                layout.panels.removeAll { $0.id == id }
                try layoutHandler(layout)
                replyHandler(["ok": true], nil)
            case "reset":
                try layoutHandler(nil)
                replyHandler(["ok": true], nil)
            default:
                throw StudioHostError.invalidWindowRequest
            }
        } catch {
            logHandler(.error, "host", error.localizedDescription)
            replyHandler(nil, error.localizedDescription)
        }
    }

    fileprivate func handleConsoleMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let value = body["message"] as? String else { return }
        let rawLevel = body["level"] as? String
        let level: StudioLogLevel = switch rawLevel {
        case "warn": .warning
        case "error": .error
        default: .info
        }
        logHandler(level, "console", value)
    }

    private func recordFailure(_ error: any Error) {
        isLoading = false
        errorMessage = error.localizedDescription
        logHandler(.error, "webview", error.localizedDescription)
    }

    private func spatialLayout(from payload: [String: Any]) throws -> SpatialAppLayout {
        guard let rawPanels = payload["panels"] as? [Any] else {
            throw SpatialWindowError.invalidPanelCount
        }
        let primaryID = (payload["primaryPanelID"] as? String)
            .map(SpatialPanelID.init(rawValue:)) ?? .primary
        return SpatialAppLayout(
            primaryPanelID: primaryID,
            panels: try rawPanels.map { try spatialPanel(from: $0, primaryPanelID: primaryID) }
        )
    }

    private func spatialPanel(
        from rawValue: Any?,
        primaryPanelID: SpatialPanelID
    ) throws -> SpatialPanelDescriptor {
        guard let value = rawValue as? [String: Any],
              let rawID = value["id"] as? String,
              let placement = value["placement"] as? [String: Any] else {
            throw SpatialWindowError.invalidPanelIdentifier
        }
        let id = SpatialPanelID(rawValue: rawID)
        let content: SpatialPanelContent
        if id == primaryPanelID, value["url"] == nil {
            content = .primary
        } else if let rawURL = value["url"] as? String,
                  let baseURL = webView.url ?? currentURL,
                  let url = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL {
            guard originPolicy?.allows(url) == true else { throw StudioHostError.disallowedURL }
            content = .web(url)
        } else {
            throw StudioHostError.invalidWindowRequest
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

    private static let dataMessageHandlerName = "extendRealityData"
    private static let windowMessageHandlerName = "extendRealityWindows"
    private static let consoleMessageHandlerName = "extendRealityConsole"

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
          const dataHandler = window.webkit?.messageHandlers?.extendRealityData;
          if (!dataHandler || window.extendReality) return;
          const read = capability => dataHandler.postMessage(capability);
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

          const consoleHandler = window.webkit?.messageHandlers?.extendRealityConsole;
          if (consoleHandler) {
            for (const level of ['log', 'warn', 'error']) {
              const original = console[level].bind(console);
              console[level] = (...values) => {
                original(...values);
                const message = values.map(value => {
                  if (typeof value === 'string') return value;
                  try { return JSON.stringify(value); } catch { return String(value); }
                }).join(' ');
                consoleHandler.postMessage({ level, message });
              };
            }
          }
        })();
        """
    }
}
