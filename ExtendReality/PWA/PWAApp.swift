import Foundation

enum PWADisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case window
    case widget

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: "Window"
        case .widget: "Widget"
        }
    }

    var systemImage: String {
        switch self {
        case .window: "macwindow"
        case .widget: "rectangle.3.group"
        }
    }
}

enum PWACapability: String, Codable, CaseIterable, Identifiable, Sendable {
    case camera
    case microphone
    case location
    case health
    case focusStatus
    case spatialWindows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .health: "Health Summary"
        case .focusStatus: "Focus Status"
        case .spatialWindows: "Spatial Windows"
        }
    }

    var explanation: String {
        switch self {
        case .camera: "Use the camera while the app is open."
        case .microphone: "Capture audio while the app is open."
        case .location: "Read your current approximate location."
        case .health: "Read today's steps, active energy, and latest heart rate."
        case .focusStatus: "See whether Focus currently silences ExtendReality notifications."
        case .spatialWindows: "Create a fixed group of spatial panels that moves with the app."
        }
    }

    var systemImage: String {
        switch self {
        case .camera: "camera.fill"
        case .microphone: "microphone.fill"
        case .location: "location.fill"
        case .health: "heart.text.square.fill"
        case .focusStatus: "moon.fill"
        case .spatialWindows: "rectangle.3.group.fill"
        }
    }
}

struct PWAAppManifest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let developer: String
    let version: String
    let launchURL: URL
    let universalLink: URL
    let allowedOrigins: [String]
    let displayModes: [PWADisplayMode]
    let requestedCapabilities: [PWACapability]
    let minimumAge: Int
    let accentHex: String

    var monogram: String {
        let words = name.split(separator: " ").prefix(2)
        let result = words.compactMap(\.first).map(String.init).joined()
        return result.isEmpty ? "A" : result.uppercased()
    }

    func validate() throws {
        guard id.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*$"#, options: .regularExpression) != nil else {
            throw PWAValidationError.invalidIdentifier(id)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !developer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PWAValidationError.missingMetadata(id)
        }
        guard Self.isSecureWebURL(launchURL), Self.isSecureWebURL(universalLink) else {
            throw PWAValidationError.insecureURL(id)
        }
        guard minimumAge >= 4, minimumAge <= 18 else {
            throw PWAValidationError.invalidAge(id)
        }
        guard !displayModes.isEmpty else {
            throw PWAValidationError.missingDisplayMode(id)
        }
        guard accentHex.range(of: #"^#[0-9A-Fa-f]{6}$"#, options: .regularExpression) != nil else {
            throw PWAValidationError.invalidAccent(id)
        }

        let normalizedOrigins = try Set(allowedOrigins.map(PWAOrigin.init(rawValue:)))
        guard normalizedOrigins.contains(try PWAOrigin(url: launchURL)) else {
            throw PWAValidationError.launchOriginNotAllowed(id)
        }
    }

    private static func isSecureWebURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }
}

struct PWACatalogDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let apps: [PWAAppManifest]

    func validatedApps() throws -> [PWAAppManifest] {
        guard schemaVersion == 1 else {
            throw PWAValidationError.unsupportedCatalogVersion(schemaVersion)
        }
        var identifiers = Set<String>()
        for app in apps {
            try app.validate()
            guard identifiers.insert(app.id).inserted else {
                throw PWAValidationError.duplicateIdentifier(app.id)
            }
        }
        return apps
    }
}

struct PWAInstallation: Codable, Equatable, Identifiable, Sendable {
    let manifest: PWAAppManifest
    let installedAt: Date
    let dataStoreIdentifier: UUID
    var grantedCapabilities: Set<PWACapability>

    var id: String { manifest.id }

    func grants(_ capability: PWACapability) -> Bool {
        grantedCapabilities.contains(capability)
    }
}

struct PWAOrigin: Codable, Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int?

    init(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased() else {
            throw PWAValidationError.invalidOrigin(url.absoluteString)
        }
        self.scheme = scheme
        self.host = host
        port = url.port
    }

    init(rawValue: String) throws {
        guard let url = URL(string: rawValue) else {
            throw PWAValidationError.invalidOrigin(rawValue)
        }
        try self.init(url: url)
        guard url.path.isEmpty || url.path == "/",
              url.query == nil,
              url.fragment == nil else {
            throw PWAValidationError.invalidOrigin(rawValue)
        }
    }

    var rawValue: String {
        if let port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }
}

struct PWAOriginPolicy: Sendable {
    private let allowedOrigins: Set<PWAOrigin>

    init(manifest: PWAAppManifest) throws {
        allowedOrigins = try Set(manifest.allowedOrigins.map(PWAOrigin.init(rawValue:)))
    }

    func allowsTopLevelNavigation(to url: URL) -> Bool {
        if url.scheme == "about" { return true }
        guard let origin = try? PWAOrigin(url: url) else { return false }
        return allowedOrigins.contains(origin)
    }
}

enum PWAValidationError: LocalizedError, Equatable {
    case unsupportedCatalogVersion(Int)
    case duplicateIdentifier(String)
    case invalidIdentifier(String)
    case missingMetadata(String)
    case insecureURL(String)
    case invalidAge(String)
    case missingDisplayMode(String)
    case invalidAccent(String)
    case invalidOrigin(String)
    case launchOriginNotAllowed(String)
    case unrequestedCapability(PWACapability)
    case ageRestricted(String, requiredAge: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedCatalogVersion(let version): "Unsupported PWA catalog version: \(version)."
        case .duplicateIdentifier(let id): "The catalog contains duplicate app identifier \(id)."
        case .invalidIdentifier(let id): "The app identifier \(id) is invalid."
        case .missingMetadata(let id): "The app \(id) is missing required metadata."
        case .insecureURL(let id): "The app \(id) must use HTTPS URLs."
        case .invalidAge(let id): "The app \(id) has an invalid minimum age."
        case .missingDisplayMode(let id): "The app \(id) has no display mode."
        case .invalidAccent(let id): "The app \(id) has an invalid accent color."
        case .invalidOrigin(let value): "The origin \(value) is invalid."
        case .launchOriginNotAllowed(let id): "The launch origin for \(id) is not allowed."
        case .unrequestedCapability(let capability): "The app did not request \(capability.title)."
        case .ageRestricted(let id, let requiredAge): "The app \(id) requires a declared age of \(requiredAge) or older."
        }
    }
}
