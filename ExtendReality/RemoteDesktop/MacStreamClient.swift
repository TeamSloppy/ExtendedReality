@preconcurrency import Foundation
import Observation

enum MacStreamConnectionState: Equatable, Sendable {
    case idle
    case searching
    case connecting(String)
    case connected(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .searching, .connecting: true
        default: false
        }
    }

    var statusText: String? {
        switch self {
        case .idle: nil
        case .searching: "Looking for ExtendReality Mac…"
        case .connecting(let name): "Starting stream on \(name)…"
        case .connected(let name): "Connected to \(name)"
        case .failed(let message): message
        }
    }
}

private struct DiscoveredMac: Equatable, Sendable {
    let name: String
    let host: String
    let port: Int
}

private enum MacStreamClientError: LocalizedError {
    case macNotFound
    case invalidAddress
    case invalidResponse
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .macNotFound:
            "No ExtendReality Mac was found on the local network. Open the Mac app and try again."
        case .invalidAddress:
            "The Mac advertised an invalid network address."
        case .invalidResponse:
            "The Mac returned an invalid stream response."
        case .rejected(let message):
            message
        }
    }
}

@MainActor
@Observable
final class MacStreamClient: NSObject {
    private(set) var state: MacStreamConnectionState = .idle
    private(set) var isCursorSyncEnabled = false
    private(set) var isCursorSyncAvailable = false
    private(set) var shareableApplications: [MacShareableApplication] = []
    private(set) var activeApplicationID: String?
    private(set) var isLoadingApplications = false
    private(set) var applicationCatalogError: String?
    let audioController: MacSessionAudioController

    @ObservationIgnored private let browser = NetServiceBrowser()
    @ObservationIgnored private var services: [String: NetService] = [:]
    @ObservationIgnored private var discoveredMacs: [String: DiscoveredMac] = [:]
    @ObservationIgnored private var isBrowsing = false
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var preferredMac: DiscoveredMac?
    @ObservationIgnored private var activeStream: MacStreamSession?
    @ObservationIgnored private var cursorSyncTask: Task<Void, Never>?
    @ObservationIgnored var cursorPositionHandler: ((MacCursorPosition) -> Void)?

    init(
        session: URLSession = .shared,
        microphoneHub: MicrophoneAudioHub = MicrophoneAudioHub()
    ) {
        self.session = session
        audioController = MacSessionAudioController(microphoneHub: microphoneHub)
        super.init()
        browser.delegate = self
    }

    var isBusy: Bool { state.isBusy }
    var statusText: String? { state.statusText }
    var audioStatusText: String? { audioController.state.statusText }
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    func setCursorSyncEnabled(_ isEnabled: Bool) {
        guard isEnabled != isCursorSyncEnabled else { return }
        isCursorSyncEnabled = isEnabled
        if isEnabled {
            startCursorSyncIfPossible()
        } else {
            cursorSyncTask?.cancel()
            cursorSyncTask = nil
        }
    }

    func refreshApplications() async {
        let previousState = state
        let preservesConnection: Bool = if case .connected = previousState { true } else { false }
        isLoadingApplications = true
        applicationCatalogError = nil
        defer { isLoadingApplications = false }
        do {
            startDiscoveryIfNeeded()
            if !preservesConnection {
                state = .searching
            }
            let mac = try await resolvedMac()
            shareableApplications = try await requestApplications(from: mac)
            state = preservesConnection ? previousState : .idle
        } catch {
            shareableApplications = []
            if preservesConnection {
                state = previousState
                applicationCatalogError = error.localizedDescription
            } else {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func dismissApplicationCatalogError() {
        applicationCatalogError = nil
    }

    func startStream(
        layout: RemoteDisplayLayout,
        applicationID: String? = nil
    ) async throws -> MacStreamSession {
        do {
            audioController.stop()
            cursorSyncTask?.cancel()
            cursorSyncTask = nil
            activeStream = nil
            isCursorSyncAvailable = false
            startDiscoveryIfNeeded()
            state = .searching
            let mac = try await resolvedMac()
            state = .connecting(mac.name)
            let stream = try await requestStream(
                from: mac,
                layout: layout,
                applicationID: applicationID
            )
            activeStream = stream
            activeApplicationID = applicationID
            isCursorSyncAvailable = stream.cursorURL != nil
            startCursorSyncIfPossible()
            state = .connected(mac.name)
            if let audio = stream.audio {
                Task { @MainActor [weak self] in
                    await self?.audioController.start(audio)
                }
            }
            return stream
        } catch {
            audioController.stop()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func dismissError() {
        if case .failed = state {
            state = .idle
        }
    }

    func stopStream() {
        cursorSyncTask?.cancel()
        cursorSyncTask = nil
        activeStream = nil
        activeApplicationID = nil
        isCursorSyncAvailable = false
        audioController.stop()
        state = .idle
    }

    private func startDiscoveryIfNeeded() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.searchForServices(ofType: "_extend-reality._tcp.", inDomain: "local.")
    }

    private func waitForMac() async throws -> DiscoveredMac {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline {
            if let mac = discoveredMacs.values.sorted(by: { $0.name < $1.name }).first {
                return mac
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MacStreamClientError.macNotFound
    }

    private func resolvedMac() async throws -> DiscoveredMac {
        if let preferredMac,
           discoveredMacs.values.contains(preferredMac) {
            return preferredMac
        }
        let mac = try await waitForMac()
        preferredMac = mac
        return mac
    }

    private func requestApplications(from mac: DiscoveredMac) async throws -> [MacShareableApplication] {
        guard let rootURL = rootURL(for: mac) else {
            throw MacStreamClientError.invalidAddress
        }
        let url = rootURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("applications")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MacStreamClientError.invalidResponse
        }
        guard 200 ..< 300 ~= response.statusCode else {
            let message = (try? JSONDecoder().decode(MacStreamAPIError.self, from: data).error)
                ?? "The Mac could not list shareable applications."
            throw MacStreamClientError.rejected(message)
        }
        let catalog = try JSONDecoder().decode(MacShareableApplicationCatalog.self, from: data)
        guard catalog.version == 1 else {
            throw MacStreamClientError.invalidResponse
        }
        return catalog.applications
    }

    private func requestStream(
        from mac: DiscoveredMac,
        layout: RemoteDisplayLayout,
        applicationID: String?
    ) async throws -> MacStreamSession {
        guard let rootURL = rootURL(for: mac),
              var startComponents = URLComponents(
                url: rootURL.appendingPathComponent("api/v1/stream/start"),
                resolvingAgainstBaseURL: false
              ) else {
            throw MacStreamClientError.invalidAddress
        }
        var queryItems = [
            URLQueryItem(name: "layout", value: layout.rawValue),
            URLQueryItem(
                name: "cursor",
                value: isCursorSyncEnabled ? "virtual" : "embedded"
            ),
        ]
        if let applicationID {
            queryItems.append(URLQueryItem(name: "application", value: applicationID))
        }
        startComponents.queryItems = queryItems
        guard let startURL = startComponents.url else {
            throw MacStreamClientError.invalidAddress
        }

        var request = URLRequest(url: startURL, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MacStreamClientError.invalidResponse
        }
        guard 200 ..< 300 ~= response.statusCode else {
            let message = (try? JSONDecoder().decode(MacStreamAPIError.self, from: data).error)
                ?? "The Mac could not start screen capture."
            throw MacStreamClientError.rejected(message)
        }
        let stream = try JSONDecoder().decode(MacStreamSession.self, from: data)
        guard stream.version == 1, !stream.streams.isEmpty else {
            throw MacStreamClientError.invalidResponse
        }
        return stream
    }

    private func rootURL(for mac: DiscoveredMac) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = mac.host
        components.port = mac.port
        components.path = "/"
        return components.url
    }

    private func startCursorSyncIfPossible() {
        cursorSyncTask?.cancel()
        cursorSyncTask = nil
        guard isCursorSyncEnabled, let cursorURL = activeStream?.cursorURL else { return }

        let session = self.session
        cursorSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    var request = URLRequest(
                        url: cursorURL,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 2
                    )
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    let (data, response) = try await session.data(for: request)
                    guard let response = response as? HTTPURLResponse,
                          200 ..< 300 ~= response.statusCode else {
                        throw MacStreamClientError.invalidResponse
                    }
                    let position = try JSONDecoder().decode(MacCursorPosition.self, from: data)
                    guard position.version == 1 else {
                        throw MacStreamClientError.invalidResponse
                    }
                    self?.cursorPositionHandler?(position)
                    try await Task.sleep(for: .milliseconds(50))
                } catch is CancellationError {
                    return
                } catch {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    private func serviceKey(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }
}

extension MacStreamClient: @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let key = serviceKey(service)
        services[key] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let key = serviceKey(service)
        services.removeValue(forKey: key)
        discoveredMacs.removeValue(forKey: key)
        if preferredMac?.host == service.hostName, preferredMac?.port == service.port {
            preferredMac = nil
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        discoveredMacs[serviceKey(sender)] = DiscoveredMac(
            name: sender.name,
            host: host,
            port: sender.port
        )
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let key = serviceKey(sender)
        services.removeValue(forKey: key)
        discoveredMacs.removeValue(forKey: key)
    }
}
