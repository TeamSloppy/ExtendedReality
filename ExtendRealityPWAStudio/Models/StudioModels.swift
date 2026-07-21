import CoreGraphics
import Foundation

enum StudioPreset: String, CaseIterable, Identifiable {
    case pwaLab
    case spatialBoard
    case spatialVideo
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pwaLab: "PWA Lab"
        case .spatialBoard: "Spatial Board"
        case .spatialVideo: "Spatial Video"
        case .custom: "Custom URL"
        }
    }

    var detail: String {
        switch self {
        case .pwaLab: "Host API and storage diagnostics"
        case .spatialBoard: "Offline spatial whiteboard"
        case .spatialVideo: "Spatial media player and library"
        case .custom: "Attach to another local server"
        }
    }

    var systemImage: String {
        switch self {
        case .pwaLab: "testtube.2"
        case .spatialBoard: "pencil.and.outline"
        case .spatialVideo: "play.rectangle.on.rectangle"
        case .custom: "link"
        }
    }

    var defaultAddress: String {
        switch self {
        case .pwaLab: BundledPWAResources.appURL(path: "pwa-lab").absoluteString
        case .spatialBoard: BundledPWAResources.appURL(path: "spatial-board").absoluteString
        case .spatialVideo: BundledPWAResources.appURL(path: "spatial-video").absoluteString
        case .custom: "http://127.0.0.1:5173/"
        }
    }

    var serverCommand: String? {
        switch self {
        case .pwaLab: "./script/run_pwa_dev_server.sh lab"
        case .spatialBoard: "./script/run_pwa_dev_server.sh board"
        case .spatialVideo: "./script/run_pwa_dev_server.sh video"
        case .custom: nil
        }
    }

    var defaultCapabilities: Set<PWACapability> {
        switch self {
        case .pwaLab: Set(PWACapability.allCases)
        case .spatialBoard, .spatialVideo, .custom: []
        }
    }

    var isBundled: Bool { self != .custom }

    var bundledPath: String {
        switch self {
        case .pwaLab: "pwa-lab"
        case .spatialBoard: "spatial-board"
        case .spatialVideo: "spatial-video"
        case .custom: ""
        }
    }
}

enum StudioLoadState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Not launched"
        case .loading: "Loading"
        case .ready: "Live"
        case .failed: "Unavailable"
        }
    }
}

enum StudioLogLevel: String {
    case info
    case warning
    case error

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

struct StudioLogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: StudioLogLevel
    let source: String
    let message: String
}

struct StudioFixtureData {
    var latitude = 55.7558
    var longitude = 37.6173
    var steps = 7_420
    var activeEnergy = 318.0
    var heartRate = 72.0
    var isFocusActive = false

    func payload(for capability: PWACapability) throws -> [String: Any] {
        switch capability {
        case .location:
            return [
                "latitude": latitude,
                "longitude": longitude,
                "horizontalAccuracy": 120.0,
                "timestamp": ISO8601DateFormatter().string(from: .now),
            ]
        case .health:
            return [
                "steps": steps,
                "activeEnergyKilocalories": activeEnergy,
                "latestHeartRateBPM": heartRate,
                "updatedAt": ISO8601DateFormatter().string(from: .now),
            ]
        case .focusStatus:
            return [
                "isFocused": isFocusActive,
                "updatedAt": ISO8601DateFormatter().string(from: .now),
            ]
        default:
            throw StudioHostError.unsupportedCapability(capability)
        }
    }
}

enum StudioHostError: LocalizedError {
    case invalidURL
    case disallowedURL
    case permissionDenied(PWACapability)
    case unsupportedCapability(PWACapability)
    case invalidWindowRequest

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP or HTTPS URL."
        case .disallowedURL: "The spatial panel URL must use the same origin as the primary PWA."
        case .permissionDenied(let capability): "The studio has denied \(capability.title) access."
        case .unsupportedCapability(let capability): "\(capability.title) has no fixture payload."
        case .invalidWindowRequest: "The spatial window request is invalid."
        }
    }
}

struct StudioOriginPolicy {
    private let scheme: String
    private let host: String
    private let port: Int?

    init(baseURL: URL) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              StudioURL.supportedSchemes.contains(scheme),
              let host = baseURL.host?.lowercased() else {
            throw StudioHostError.invalidURL
        }
        self.scheme = scheme
        self.host = host
        port = baseURL.port
    }

    func allows(_ url: URL) -> Bool {
        if url.scheme == "about" { return true }
        return url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == host
            && url.port == port
    }
}

enum StudioURL {
    static let supportedSchemes = ["http", "https", BundledPWAResources.scheme]

    static func resolve(_ rawValue: String, displayMode: PWADisplayMode) throws -> URL {
        var rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawValue.contains("://") {
            rawValue = "http://\(rawValue)"
        }
        guard let baseURL = URL(string: rawValue),
              let scheme = baseURL.scheme?.lowercased(),
              supportedSchemes.contains(scheme),
              baseURL.host != nil,
              scheme != BundledPWAResources.scheme
                || baseURL.host?.lowercased() == BundledPWAResources.host,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw StudioHostError.invalidURL
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "extendDisplayMode" }
        items.append(URLQueryItem(name: "extendDisplayMode", value: displayMode.rawValue))
        components.queryItems = items
        if scheme == BundledPWAResources.scheme, !components.path.hasSuffix("/") {
            components.path += "/"
        }
        guard let url = components.url else { throw StudioHostError.invalidURL }
        return url
    }
}

struct StudioWindowTransform: Equatable {
    var yaw = 0.0
    var pitch = 0.0
    var distance = 1.0
    var scale = 1.0

    mutating func clamp() {
        yaw = yaw.clamped(to: -42 ... 42)
        pitch = pitch.clamped(to: -24 ... 24)
        distance = distance.clamped(to: WindowTransform3DoF.virtualDistanceRange)
        scale = scale.clamped(to: SpatialAppTransform3DoF.scaleRange)
    }
}

struct StudioCameraTransform: Equatable {
    var yaw = 0.0
    var pitch = 0.0

    mutating func clamp() {
        yaw = yaw.clamped(to: -42 ... 42)
        pitch = pitch.clamped(to: -24 ... 24)
    }
}

struct StudioProjectedPanel: Identifiable, Equatable {
    let descriptor: SpatialPanelDescriptor
    let frame: CGRect

    var id: SpatialPanelID { descriptor.id }
}

enum StudioProjection {
    static func project(
        layout: SpatialAppLayout,
        transform: StudioWindowTransform,
        camera: StudioCameraTransform = StudioCameraTransform(),
        in viewport: CGRect
    ) -> [StudioProjectedPanel] {
        layout.panels.map { panel in
            let placement = panel.placement
            let distance = (transform.distance + placement.depth * transform.scale)
                .clamped(to: WindowTransform3DoF.virtualDistanceRange)
            let centerX = viewport.midX
                + CGFloat((transform.yaw + placement.yaw * transform.scale - camera.yaw) / 42)
                * viewport.width * 0.52
            let centerY = viewport.midY
                - CGFloat((transform.pitch + placement.pitch * transform.scale - camera.pitch) / 24)
                * viewport.height * 0.44
            let width = viewport.width * CGFloat(placement.width * transform.scale / distance)
            let height = viewport.height * CGFloat(placement.height * transform.scale / distance)
            return StudioProjectedPanel(
                descriptor: panel,
                frame: CGRect(
                    x: centerX - width / 2,
                    y: centerY - height / 2,
                    width: width,
                    height: height
                )
            )
        }
    }

    static func boundingFrame(for panels: [StudioProjectedPanel]) -> CGRect {
        panels.map(\.frame).reduce(.null) { $0.union($1) }
    }
}
