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

    @ObservationIgnored private let browser = NetServiceBrowser()
    @ObservationIgnored private var services: [String: NetService] = [:]
    @ObservationIgnored private var discoveredMacs: [String: DiscoveredMac] = [:]
    @ObservationIgnored private var isBrowsing = false
    @ObservationIgnored private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        super.init()
        browser.delegate = self
    }

    var isBusy: Bool { state.isBusy }
    var statusText: String? { state.statusText }

    func startStream(layout: RemoteDisplayLayout) async throws -> MacStreamSession {
        do {
            startDiscoveryIfNeeded()
            state = .searching
            let mac = try await waitForMac()
            state = .connecting(mac.name)
            let stream = try await requestStream(from: mac, layout: layout)
            state = .connected(mac.name)
            return stream
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func dismissError() {
        if case .failed = state {
            state = .idle
        }
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

    private func requestStream(
        from mac: DiscoveredMac,
        layout: RemoteDisplayLayout
    ) async throws -> MacStreamSession {
        var rootComponents = URLComponents()
        rootComponents.scheme = "http"
        rootComponents.host = mac.host
        rootComponents.port = mac.port
        rootComponents.path = "/"
        guard let rootURL = rootComponents.url,
              var startComponents = URLComponents(
                url: rootURL.appendingPathComponent("api/v1/stream/start"),
                resolvingAgainstBaseURL: false
              ) else {
            throw MacStreamClientError.invalidAddress
        }
        startComponents.queryItems = [URLQueryItem(name: "layout", value: layout.rawValue)]
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
