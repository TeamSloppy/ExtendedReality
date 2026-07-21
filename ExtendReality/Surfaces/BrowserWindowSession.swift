import CoreGraphics
import Foundation
import Observation

enum BrowserURLResolver {
    static func resolve(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.contains("://") {
            guard let components = URLComponents(string: value),
                  let scheme = components.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  components.host != nil else { return nil }
            return components.url
        }

        if isHostLike(value),
           let components = URLComponents(string: "https://\(value)"),
           components.host != nil {
            return components.url
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: value)]
        return components.url
    }

    private static func isHostLike(_ value: String) -> Bool {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let host = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        return host.localizedCaseInsensitiveCompare("localhost") == .orderedSame
            || host.contains(".")
            || host.contains(":")
    }
}

@MainActor
struct BrowserTab: Identifiable {
    let id: UUID
    let session: BrowserSession

    var displayTitle: String {
        if session.address.isEmpty { return "New Tab" }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != "Browser" { return title }
        return URL(string: session.address)?.host ?? "Browser"
    }
}

enum BrowserChromeTarget: Equatable {
    case tab(UUID)
    case closeTab(UUID)
    case newTab
    case back
    case forward
    case address
    case reload
    case content(CGPoint)
}

struct BrowserChromeLayout: Equatable {
    static let tabBarHeight: CGFloat = 42
    static let navigationBarHeight: CGFloat = 52
    static let newTabWidth: CGFloat = 44
    static let tabCountWidth: CGFloat = 50
    static let navigationButtonWidth: CGFloat = 44
    static let reloadButtonWidth: CGFloat = 48

    static var chromeHeight: CGFloat { tabBarHeight + navigationBarHeight }

    let size: CGSize
    let tabIDs: [UUID]

    func target(at normalizedPosition: CGPoint) -> BrowserChromeTarget? {
        guard size.width > 0, size.height > 0 else { return nil }
        let point = CGPoint(
            x: normalizedPosition.x.clamped(to: 0 ... 1) * size.width,
            y: normalizedPosition.y.clamped(to: 0 ... 1) * size.height
        )

        if point.y < Self.tabBarHeight {
            return tabTarget(at: point.x)
        }
        if point.y < Self.chromeHeight {
            return navigationTarget(at: point.x)
        }
        return .content(contentPosition(for: normalizedPosition, clamped: true))
    }

    func contentPosition(for normalizedPosition: CGPoint, clamped: Bool = false) -> CGPoint {
        guard size.width > 0, size.height > Self.chromeHeight else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let point = CGPoint(
            x: normalizedPosition.x * size.width,
            y: normalizedPosition.y * size.height
        )
        let x = point.x / size.width
        let y = (point.y - Self.chromeHeight) / (size.height - Self.chromeHeight)
        if clamped {
            return CGPoint(x: x.clamped(to: 0 ... 1), y: y.clamped(to: 0 ... 1))
        }
        return CGPoint(x: x, y: y)
    }

    private func tabTarget(at x: CGFloat) -> BrowserChromeTarget? {
        if x >= size.width - Self.newTabWidth { return .newTab }
        let tabAreaWidth = max(size.width - Self.newTabWidth - Self.tabCountWidth, 0)
        guard x < tabAreaWidth, !tabIDs.isEmpty else { return nil }
        let tabWidth = tabAreaWidth / CGFloat(tabIDs.count)
        guard tabWidth > 0 else { return nil }
        let index = min(Int(x / tabWidth), tabIDs.count - 1)
        let id = tabIDs[index]
        let localX = x - CGFloat(index) * tabWidth
        let closeWidth = min(30, tabWidth * 0.34)
        return localX >= tabWidth - closeWidth ? .closeTab(id) : .tab(id)
    }

    private func navigationTarget(at x: CGFloat) -> BrowserChromeTarget {
        if x < Self.navigationButtonWidth { return .back }
        if x < Self.navigationButtonWidth * 2 { return .forward }
        if x >= size.width - Self.reloadButtonWidth { return .reload }
        return .address
    }
}

@MainActor
@Observable
final class BrowserWindowSession: InputTarget {
    typealias SessionFactory = (_ initialURL: String, _ loadsContent: Bool) -> BrowserSession

    static let maximumTabCount = 8

    private(set) var tabs: [BrowserTab]
    private(set) var activeTabID: UUID
    private(set) var addressFocusRequest = UUID()
    private(set) var hoveredChromeTarget: BrowserChromeTarget?
    private(set) var spatialSurfaceSize = CGSize(width: 960, height: 540)

    @ObservationIgnored private let sessionFactory: SessionFactory
    @ObservationIgnored private let textInputFocusHandler: () -> Void
    @ObservationIgnored private var pressedChromeTarget: BrowserChromeTarget?
    @ObservationIgnored private var pressedContentSession: BrowserSession?
    @ObservationIgnored private var isAddressInputActive = false

    init(
        initialURL: String,
        loadsContent: Bool = true,
        textInputFocusHandler: @escaping () -> Void = {},
        sessionFactory: @escaping SessionFactory = {
            BrowserSession(initialURL: $0, loadsContent: $1)
        }
    ) {
        self.sessionFactory = sessionFactory
        self.textInputFocusHandler = textInputFocusHandler
        let session = sessionFactory(initialURL, loadsContent && !initialURL.isEmpty)
        let tab = BrowserTab(id: UUID(), session: session)
        tabs = [tab]
        activeTabID = tab.id
        configureNewWindowHandling(for: session)
    }

    var activeTab: BrowserTab {
        tabs.first(where: { $0.id == activeTabID }) ?? tabs[0]
    }

    var activeSession: BrowserSession { activeTab.session }
    var canCreateTab: Bool { tabs.count < Self.maximumTabCount }
    var tabCountLabel: String { "\(tabs.count)/\(Self.maximumTabCount)" }

    @discardableResult
    func addTab(
        request: URLRequest? = nil,
        requestsAddressFocus: Bool = true
    ) -> UUID? {
        guard canCreateTab else {
            if let request { activeSession.load(request) }
            return nil
        }
        isAddressInputActive = false
        let session = sessionFactory("", false)
        let tab = BrowserTab(id: UUID(), session: session)
        tabs.append(tab)
        configureNewWindowHandling(for: session)
        activeTabID = tab.id
        if let request {
            session.load(request)
        } else if requestsAddressFocus {
            addressFocusRequest = UUID()
        }
        return tab.id
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        isAddressInputActive = false
        activeTabID = id
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        isAddressInputActive = false
        let wasActive = id == activeTabID
        tabs[index].session.newWindowHandler = nil
        tabs.remove(at: index)
        if wasActive {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func loadActive() {
        isAddressInputActive = false
        activeSession.load()
    }

    func reloadActive() {
        activeSession.reload()
    }

    func goBack() {
        activeSession.goBack()
    }

    func goForward() {
        activeSession.goForward()
    }

    func requestAddressFocus() {
        addressFocusRequest = UUID()
    }

    func updateSpatialSurfaceSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, spatialSurfaceSize != size else { return }
        spatialSurfaceSize = size
    }

    func contentPosition(for normalizedPosition: CGPoint) -> CGPoint? {
        let layout = chromeLayout
        guard case .content(let position) = layout.target(at: normalizedPosition) else { return nil }
        return position
    }

    func handle(_ command: InputCommand) {
        if case .insertText(let text) = command, isAddressInputActive {
            isAddressInputActive = false
            activeSession.address = text
            loadActive()
            return
        }
        switch command {
        case .pointerMoved(let position):
            handlePointerMoved(position)
        case .pointerDown(let position):
            handlePointerDown(position)
        case .pointerUp(let position):
            handlePointerUp(position)
        case .scroll, .insertText, .back, .media:
            activeSession.handle(command)
        }
    }

    private var chromeLayout: BrowserChromeLayout {
        BrowserChromeLayout(size: spatialSurfaceSize, tabIDs: tabs.map(\.id))
    }

    private func configureNewWindowHandling(for session: BrowserSession) {
        session.newWindowHandler = { [weak self] request in
            self?.openNewWindow(request)
        }
    }

    private func openNewWindow(_ request: URLRequest) {
        _ = addTab(request: request, requestsAddressFocus: false)
    }

    private func handlePointerMoved(_ position: CGPoint) {
        guard let target = chromeLayout.target(at: position) else {
            hoveredChromeTarget = nil
            return
        }
        if case .content(let contentPosition) = target {
            hoveredChromeTarget = nil
            activeSession.handle(.pointerMoved(normalizedPosition: contentPosition))
        } else {
            hoveredChromeTarget = target
        }
    }

    private func handlePointerDown(_ position: CGPoint) {
        guard let target = chromeLayout.target(at: position) else { return }
        if case .content(let contentPosition) = target {
            isAddressInputActive = false
            let session = activeSession
            pressedContentSession = session
            session.handle(.pointerDown(normalizedPosition: contentPosition))
        } else {
            pressedChromeTarget = target
        }
    }

    private func handlePointerUp(_ position: CGPoint) {
        if let session = pressedContentSession {
            pressedContentSession = nil
            let contentPosition = chromeLayout.contentPosition(for: position, clamped: true)
            session.handle(.pointerUp(normalizedPosition: contentPosition))
            return
        }

        let pressedTarget = pressedChromeTarget
        pressedChromeTarget = nil
        guard let pressedTarget,
              chromeLayout.target(at: position) == pressedTarget else { return }
        perform(pressedTarget)
    }

    private func perform(_ target: BrowserChromeTarget) {
        switch target {
        case .tab(let id): selectTab(id)
        case .closeTab(let id): closeTab(id)
        case .newTab:
            guard addTab(requestsAddressFocus: false) != nil else { return }
            activateSpatialAddressInput()
        case .back:
            isAddressInputActive = false
            goBack()
        case .forward:
            isAddressInputActive = false
            goForward()
        case .address:
            activateSpatialAddressInput()
        case .reload:
            isAddressInputActive = false
            reloadActive()
        case .content: break
        }
    }

    private func activateSpatialAddressInput() {
        isAddressInputActive = true
        requestAddressFocus()
        textInputFocusHandler()
    }
}
